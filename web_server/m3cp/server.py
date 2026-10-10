"""Run from repository root: cd web_server; python -m m3cp.server --config ..."""
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import argparse
import json
import logging
import queue
import socket
import struct
import threading
import time
import numpy as np
from pc_perception.protocol import decode_mid360
from car_showcase.mesh import make_mesh
from perception_model import decode_snapshot
from . import wire
from .local_map import LocalMap
from .recording import Segments

LOG = logging.getLogger(__name__)

def mesh_binary(mesh):
    return (struct.pack('<4I',0x4d335348,len(mesh.vertices),len(mesh.triangles),1)
            +mesh.vertices.astype('<f4').tobytes()+mesh.normals.astype('<f4').tobytes()
            +mesh.triangles.astype('<u4').tobytes()+mesh.observed.astype('u1').tobytes()
            +mesh.raw_vertices.astype('<f4').tobytes())

class Hub:
    def __init__(self, config, free_bytes=None):
        self.config=config
        self.stop=threading.Event()
        self.lock=threading.Lock()
        self.recorder=Segments(config.get('record_dir','results/host_linux'),
            config.get('segment_seconds',60),config.get('segment_bytes',256*1024**2),
            config.get('disk_reserve_bytes',1024**3),free_bytes)
        self.map=LocalMap(config.get('map',{}))
        self.queue=queue.Queue(maxsize=256)
        self.camera=None
        self.camera_generation=0
        self.result=None
        self.received={}
        self.stats={k:dict(good=0,bad=0,bad_source=0,missing=0,duplicate=0,reorder=0,reconnect=0,
                           connected=False,synthetic=False) for k in wire.PORTS}
        self.sequence={}
        self.listeners=[]
        self.threads=[]
        self.processing_drops=0
        self.cloud=deque(maxlen=256)
        self.mesh=mesh_binary(make_mesh(np.zeros((0,3))))
        self.mesh_version=0
        self.mesh_stats={}
        self.replay_active=False
        self.playhead_us=0

    def ingest(self, rec, packet=None):
        now=time.monotonic()
        with self.lock:
            key=rec.kind
            old=self.sequence.get(key)
            if old and old[0]==rec.boot_id:
                delta=(rec.sequence-old[1])&0xffffffff
                if delta==0:
                    self.stats[key]['duplicate']+=1;return
                if delta>=0x80000000:
                    self.stats[key]['reorder']+=1;return
                self.stats[key]['missing']+=delta-1
            self.sequence[key]=(rec.boot_id,rec.sequence)
            self.stats[key]['good']+=1
            self.stats[key]['synthetic']=bool(rec.flags&1)
            if rec.flags&4:
                self.stats[key]['bad_source']+=1
                if packet is not None:self.recorder.write(rec,packet)
                return
            self.received[key]=now
            if key==2:
                self.camera=rec.payload;self.camera_generation+=1
            elif key==4:
                self.result=decode_snapshot(rec.payload)
                self.result['received_at']=now
                self.result['synthetic']=bool(rec.flags&1)
            else:
                try:self.queue.put_nowait(rec)
                except queue.Full:
                    # Drop oldest processing work. Recording is a separate path.
                    try:self.queue.get_nowait()
                    except queue.Empty:pass
                    self.processing_drops+=1
                    try:self.queue.put_nowait(rec)
                    except queue.Full:self.processing_drops+=1
        if packet is not None:
            self.recorder.write(rec,packet)

    def state(self):
        with self.lock:
            now=time.monotonic()
            streams={str(k):{**v,'age_ms':round((now-self.received[k])*1000) if k in self.received else None}
                     for k,v in self.stats.items()}
            result=dict(self.result) if self.result else None
            if result:
                elapsed=max(0,int((now-result.pop('received_at'))*1e6))
                result['radar_age_ms']=max(0,result['now_us']-result['radar_us']+elapsed)//1000
                result['motion_age_ms']=max(0,result['now_us']-result['motion_us']+elapsed)//1000
                if result['radar_age_ms']>150:
                    result['objects']=[];result['radar_valid']=False
                if result['motion_age_ms']>1000:result['motion_valid']=False
            pose_fresh=3 in self.received and now-self.received[3]<=1
            return {'streams':streams,'result':result,'recording':self.recorder.status,
                    'processing_drops':self.processing_drops,'mesh_version':self.mesh_version,
                    'mesh':dict(self.mesh_stats),'map_valid':pose_fresh and self.map.status=='odom_fusion_no_loop_closure',
                    'map_status':self.map.status if pose_fresh else 'pose_missing_or_stale',
                    'map_points':len(self.map.cells),'trajectory':list(self.map.trajectory) if pose_fresh else [],
                    'pose':{'position_m':(self.map.poses[-1][1]/1000).tolist(),'yaw_rad':float(self.map.poses[-1][2][2])} if pose_fresh and self.map.poses else None,
                    'replay':self.replay_active,'playhead_us':self.playhead_us}

    def camera_jpeg(self):
        import cv2
        with self.lock:payload=self.camera
        if payload is None:return None
        w,h,fmt,stride,_=wire.raw.CAMERA_META.unpack_from(payload)
        if fmt==wire.raw.CAMERA_YUYV:
            bgr=cv2.cvtColor(np.frombuffer(payload[12:],np.uint8).reshape(h,w,2),cv2.COLOR_YUV2BGR_YUY2)
        else:
            bgr=cv2.cvtColor(np.frombuffer(payload[12:],np.uint8).reshape(h,w,2),cv2.COLOR_BGR5652BGR)
        if self.config.get('camera_rotation',0)==180:bgr=cv2.rotate(bgr,cv2.ROTATE_180)
        return cv2.imencode('.jpg',bgr,[cv2.IMWRITE_JPEG_QUALITY,80])[1].tobytes()

    def _receiver(self,kind,listener):
        while not self.stop.is_set():
            try:conn,_=listener.accept()
            except socket.timeout:continue
            except OSError:break
            with self.lock:
                self.stats[kind]['connected']=True;self.stats[kind]['reconnect']+=1
            conn.settimeout(.5)
            buffer=bytearray()
            try:
                with conn:
                    while not self.stop.is_set():
                        try:data=conn.recv(65536)
                        except socket.timeout:continue
                        if not data:break
                        buffer.extend(data)
                        while len(buffer)>=48:
                            fields=wire.header(buffer[:48],kind)
                            total=48+fields[6]
                            if len(buffer)<total:break
                            packet=bytes(buffer[:total]);del buffer[:total]
                            try:rec=wire.decode(packet,kind)
                            except ValueError:
                                with self.lock:self.stats[kind]['bad']+=1
                                continue
                            self.ingest(rec,packet)
                        if len(buffer)>48+wire.MAX_PAYLOAD[kind]:raise ValueError('bounded buffer exceeded')
            except (OSError,ValueError) as error:
                with self.lock:self.stats[kind]['bad']+=1
                LOG.warning('stream %s disconnected: %s',kind,error)
            finally:
                with self.lock:self.stats[kind]['connected']=False

    def _processor(self):
        next_mesh=time.monotonic()
        period=.5
        latest_stamp=0
        boot=None
        while not self.stop.is_set():
            try:rec=self.queue.get(timeout=.02)
            except queue.Empty:rec=None
            if rec:
                try:
                    if rec.kind==3:
                        with self.lock:self.map.odom(rec)
                    elif rec.kind==1:
                        packet=decode_mid360(rec.payload,rec.capture_us*1000)
                        points=np.column_stack([packet.points[a] for a in ('x','y','z')])
                        if boot!=rec.boot_id:
                            with self.lock:self.map.reset()
                            self.cloud.clear();boot=rec.boot_id
                        latest_stamp=rec.capture_us
                        self.cloud.append((latest_stamp,points))
                        while self.cloud and latest_stamp-self.cloud[0][0]>200000:self.cloud.popleft()
                        with self.lock:self.map.fuse(points,latest_stamp)
                except ValueError as error:
                    with self.lock:self.stats[rec.kind]['bad']+=1
                    if self.stats[rec.kind]['bad']<=3:LOG.warning('source %s invalid: %s',rec.kind,error)
            if time.monotonic()>=next_mesh and self.cloud:
                with self.lock:
                    fused=self.map.body_points(latest_stamp) if self.map.status=='odom_fusion_no_loop_closure' else np.zeros((0,3))
                points=fused if len(fused) else np.concatenate([p for _,p in self.cloud])
                # Bound the mesher input independently of network recording.
                points=points[-200000:]
                start=time.perf_counter();mesh=make_mesh(points,1.0)
                elapsed=time.perf_counter()-start
                period=.5 if elapsed<.25 else 1 if elapsed<.7 else 2
                with self.lock:
                    self.mesh=mesh_binary(mesh);self.mesh_version+=1
                    self.mesh_stats={'triangles':len(mesh.triangles),'vertices':len(mesh.vertices),
                                     'build_ms':round(elapsed*1000,2),'period_s':period,
                                     'p95_shift_mm':round(mesh.p95_shift_mm,2),
                                     'source':'odom_map' if len(fused) else 'local_200ms'}
                next_mesh=time.monotonic()+period

    def start(self):
        for kind,port in self.config.get('ports',wire.PORTS).items():
            kind=int(kind)
            listener=socket.socket();listener.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
            listener.bind((self.config.get('bind','10.42.0.1'),int(port)));listener.listen(2);listener.settimeout(.5)
            self.listeners.append(listener)
            thread=threading.Thread(target=self._receiver,args=(kind,listener),daemon=True)
            thread.start();self.threads.append(thread)
        self.processing_thread=threading.Thread(target=self._processor,daemon=True)
        self.processing_thread.start()

    def close(self):
        self.stop.set()
        for listener in self.listeners:listener.close()
        for thread in self.threads:thread.join(2)
        if hasattr(self,'processing_thread'):self.processing_thread.join(5)
        self.recorder.close()

def serve(hub,host,port):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            path=self.path.split('?')[0]
            if path=='/api/state':payload=json.dumps(hub.state(),allow_nan=False).encode();mime='application/json'
            elif path=='/mesh.m3mesh':
                with hub.lock:payload=hub.mesh
                mime='application/x-mid360-mesh'
            elif path=='/camera.jpg':
                payload=hub.camera_jpeg();mime='image/jpeg'
                if payload is None:self.send_error(404,'camera unavailable');return
            elif path=='/':payload=(Path(__file__).resolve().parents[2]/'user_app'/'m3cp'/'index.html').read_bytes();mime='text/html; charset=utf-8'
            else:self.send_error(404);return
            self.send_response(200);self.send_header('Content-Type',mime)
            self.send_header('Content-Length',str(len(payload)));self.send_header('Cache-Control','no-store');self.end_headers()
            try:self.wfile.write(payload)
            except (BrokenPipeError,ConnectionResetError,ConnectionAbortedError):pass
        def log_message(self,*args):pass
    server=ThreadingHTTPServer((host,port),Handler)
    return server

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--config',required=True,type=Path)
    args=parser.parse_args();config=json.loads(args.config.read_text(encoding='utf-8-sig'))
    logging.basicConfig(level=logging.INFO,format='%(message)s')
    hub=Hub(config)
    try:
        hub.start();http=serve(hub,config.get('web_bind','0.0.0.0'),config.get('web_port',8765))
        LOG.info('receiver ready, web port %s',http.server_port)
        http.serve_forever()
    except KeyboardInterrupt:pass
    finally:hub.close()

if __name__=='__main__':main()
