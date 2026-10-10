"""Local live MID-360 surface viewer; visualization stays outside integer core.

The surface is rebuilt from at most three recent scans while the sensor is
stationary. No moving-platform fusion or camera calibration is implied.
"""

from __future__ import annotations

import argparse
import base64
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import select
import socket
import threading
import time
from urllib.parse import parse_qs, urlparse

import numpy as np

from pc_perception.frame import FrameAssembler
from pc_perception.grid import GridProcessor
from pc_perception.protocol import PacketError, decode_mid360
from render_surface_twin import colors, line_data, reconstruct


PAGE = r"""<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>MID-360 实时表面场景</title><style>
html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#07121c;color:#e9f2f6;font:14px system-ui,Segoe UI,sans-serif}
canvas{display:block;width:100vw;height:100vh;cursor:grab}canvas:active{cursor:grabbing}
.panel{position:absolute;left:18px;top:18px;background:#0b1c2ddd;border:1px solid #45647a;border-radius:12px;padding:14px 18px;line-height:1.65;max-width:390px;backdrop-filter:blur(8px)}
h1{margin:0 0 6px;font-size:20px}.badge{display:inline-block;background:#15464c;color:#92e9d3;border-radius:18px;padding:2px 8px;font-size:12px}
.status{font-weight:700}.ok{color:#80e0a3}.bad{color:#ff938b}.muted{color:#b3c9d5;font-size:12px;margin-top:7px}
button{background:#143b4c;border:1px solid #648d9d;color:white;border-radius:7px;padding:5px 10px;margin-top:8px;cursor:pointer}
.foot{position:absolute;right:18px;bottom:15px;background:#0b1c2ddd;border:1px solid #45647a;border-radius:8px;padding:7px 11px}
</style></head><body><canvas id="view"></canvas><div class="panel"><span class="badge">MID-360 · 实时数据</span><h1>场景表面预览</h1>
<div id="state" class="status bad">等待雷达扫描…</div><div id="count">UDP 包：0　扫描：0</div><div id="mesh">表面：等待生成</div><div id="target">最近候选：—</div>
<div class="muted">橙色：最近的紧凑障碍物候选；蓝灰色：其余可见表面。拖动旋转，滚轮缩放，双击复位。</div>
<button id="reset">复位视角</button><div class="muted">固定使用最近 3 次扫描。雷达保持静止；移动时多帧会错位。网孔和遮挡背面无法完整还原。</div></div>
<div class="foot">前方 +X · 左侧 +Y · 高度 +Z　|　此页面仅连接本机</div>
<script>
const cv=document.getElementById('view'),gl=cv.getContext('webgl2',{antialias:true,depth:true});
if(!gl){document.getElementById('state').textContent='浏览器不支持 WebGL2';throw new Error('WebGL2 unavailable')}
function decode(s,Type){let t=atob(s),b=new Uint8Array(t.length);for(let i=0;i<t.length;i++)b[i]=t.charCodeAt(i);return new Type(b.buffer)}
const vs=`#version 300 es
precision highp float;layout(location=0) in vec3 a_pos;layout(location=1) in vec3 a_normal;layout(location=2) in vec3 a_color;
uniform vec3 u_cam,u_forward,u_right,u_up;uniform float u_focal,u_aspect,u_near,u_far;out vec3 v_normal,v_color;
void main(){vec3 rel=a_pos-u_cam;float d=dot(rel,u_forward);float A=(u_far+u_near)/(u_far-u_near);float B=-2.0*u_far*u_near/(u_far-u_near);
gl_Position=vec4(dot(rel,u_right)*u_focal/u_aspect,dot(rel,u_up)*u_focal,A*d+B,d);v_normal=a_normal;v_color=a_color;}`;
const fs=`#version 300 es
precision highp float;in vec3 v_normal,v_color;uniform bool u_line;out vec4 out_color;
void main(){float light=abs(dot(normalize(v_normal),normalize(vec3(-.45,-.35,.83))));out_color=vec4(v_color*(u_line?1.0:(.46+.54*light)),1.0);}`;
function shader(t,s){let q=gl.createShader(t);gl.shaderSource(q,s);gl.compileShader(q);if(!gl.getShaderParameter(q,gl.COMPILE_STATUS))throw new Error(gl.getShaderInfoLog(q));return q}
const prog=gl.createProgram();gl.attachShader(prog,shader(gl.VERTEX_SHADER,vs));gl.attachShader(prog,shader(gl.FRAGMENT_SHADER,fs));gl.linkProgram(prog);
if(!gl.getProgramParameter(prog,gl.LINK_STATUS))throw new Error(gl.getProgramInfoLog(prog));gl.useProgram(prog);
const loc={};for(const n of ['u_cam','u_forward','u_right','u_up','u_focal','u_aspect','u_near','u_far','u_line'])loc[n]=gl.getUniformLocation(prog,n);
function makeVAO(withIndex){let vao=gl.createVertexArray();gl.bindVertexArray(vao);let vb=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,vb);for(let i=0;i<3;i++){gl.enableVertexAttribArray(i);gl.vertexAttribPointer(i,3,gl.FLOAT,false,36,i*12)}
let ib=null;if(withIndex){ib=gl.createBuffer();gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER,ib)}return {vao,vb,ib}}
const mesh=makeVAO(true),edges=makeVAO(false);let nIndices=0,nLines=0,seq=0,yaw=-2.4,pitch=.45,radius=2.7,drag=false,lastX=0,lastY=0,scheduled=false;
const target=[1,.2,.6];function norm(v){let n=Math.hypot(...v);return v.map(x=>x/n)}function cross(a,b){return [a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]]}
function render(){scheduled=false;let d=devicePixelRatio||1,w=Math.round(innerWidth*d),h=Math.round(innerHeight*d);if(cv.width!==w||cv.height!==h){cv.width=w;cv.height=h}gl.viewport(0,0,w,h);
gl.clearColor(.027,.071,.11,1);gl.clear(gl.COLOR_BUFFER_BIT|gl.DEPTH_BUFFER_BIT);gl.enable(gl.DEPTH_TEST);gl.disable(gl.CULL_FACE);
let cam=[target[0]+radius*Math.cos(pitch)*Math.cos(yaw),target[1]+radius*Math.cos(pitch)*Math.sin(yaw),target[2]+radius*Math.sin(pitch)],f=norm(target.map((v,i)=>v-cam[i])),r=norm(cross(f,[0,0,1])),u=cross(r,f);
for(const [n,v] of [['u_cam',cam],['u_forward',f],['u_right',r],['u_up',u]])gl.uniform3fv(loc[n],v);
gl.uniform1f(loc.u_focal,1.75);gl.uniform1f(loc.u_aspect,w/h);gl.uniform1f(loc.u_near,.05);gl.uniform1f(loc.u_far,50);
gl.uniform1i(loc.u_line,0);gl.bindVertexArray(mesh.vao);if(nIndices)gl.drawElements(gl.TRIANGLES,nIndices,gl.UNSIGNED_INT,0);
gl.uniform1i(loc.u_line,1);gl.bindVertexArray(edges.vao);if(nLines)gl.drawArrays(gl.LINES,0,nLines)}
function schedule(){if(!scheduled){scheduled=true;requestAnimationFrame(render)}}
function updateMesh(x){let v=decode(x.vertices,Float32Array),i=decode(x.indices,Uint32Array),l=decode(x.lines,Float32Array);
gl.bindVertexArray(mesh.vao);gl.bindBuffer(gl.ARRAY_BUFFER,mesh.vb);gl.bufferData(gl.ARRAY_BUFFER,v,gl.DYNAMIC_DRAW);gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER,mesh.ib);gl.bufferData(gl.ELEMENT_ARRAY_BUFFER,i,gl.DYNAMIC_DRAW);nIndices=i.length;
gl.bindVertexArray(edges.vao);gl.bindBuffer(gl.ARRAY_BUFFER,edges.vb);gl.bufferData(gl.ARRAY_BUFFER,l,gl.DYNAMIC_DRAW);nLines=l.length/9;schedule()}
function status(s){document.getElementById('state').textContent=s.live?'雷达在线 · 场景持续刷新':'等待雷达 / 最近画面已过期';document.getElementById('state').className='status '+(s.live?'ok':'bad');
document.getElementById('count').textContent=`UDP 包：${s.packets}　扫描：${s.scans}　坏包：${s.bad_packets}`;
document.getElementById('mesh').textContent=`表面：${s.triangles.toLocaleString()} 个三角面　画面年龄：${s.mesh_age_ms===null?'—':s.mesh_age_ms+' ms'}`;
document.getElementById('target').textContent=s.live&&s.target_mm?`最近紧凑候选：${(s.target_mm/1000).toFixed(2)} m`:'最近紧凑候选：—'}
async function poll(){try{let r=await fetch('/frame?since='+seq,{cache:'no-store'});if(!r.ok)throw new Error('HTTP '+r.status);let x=await r.json();status(x.status);if(x.seq>seq&&x.vertices){seq=x.seq;updateMesh(x)}}catch(e){document.getElementById('state').textContent='连接中断：'+e.message;document.getElementById('state').className='status bad'}setTimeout(poll,250)}
cv.addEventListener('pointerdown',e=>{drag=true;lastX=e.clientX;lastY=e.clientY;cv.setPointerCapture(e.pointerId)});
cv.addEventListener('pointermove',e=>{if(!drag)return;yaw+=(e.clientX-lastX)*.006;pitch=Math.max(.04,Math.min(1.45,pitch+(e.clientY-lastY)*.006));lastX=e.clientX;lastY=e.clientY;schedule()});
cv.addEventListener('pointerup',()=>drag=false);cv.addEventListener('wheel',e=>{e.preventDefault();radius=Math.max(2.5,Math.min(25,radius*Math.exp(e.deltaY*.001)));schedule()},{passive:false});
function reset(){yaw=-2.4;pitch=.45;radius=2.7;schedule()}cv.addEventListener('dblclick',reset);document.getElementById('reset').onclick=reset;window.addEventListener('resize',schedule);render();poll();
</script></body></html>"""


class LiveTwin:
    def __init__(self, lidar_ip: str, bind_ip: str, udp_port: int, window_scans: int = 3):
        self.lidar_ip = lidar_ip
        self.bind_ip = bind_ip
        self.udp_port = udp_port
        self.scans = deque(maxlen=window_scans)
        self.assembler = FrameAssembler()
        self.grid = GridProcessor()
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.packets = self.bad_packets = self.scan_count = 0
        self.last_packet_ns = self.last_mesh_ns = 0
        self.seq = 0
        self.target_mm = None
        self.triangles = 0
        self.latest_frame = {}

    def ingest_packet(self, payload: bytes, host_ns: int):
        try:
            packet = decode_mid360(payload, host_ns)
        except PacketError:
            with self.lock:
                self.bad_packets += 1
            return
        with self.lock:
            self.packets += 1
            self.last_packet_ns = host_ns
        scan = self.assembler.add(packet)
        if scan is None:
            return
        self.scans.append(scan.points)
        result = self.grid.process(scan.points)
        with self.lock:
            self.scan_count += 1
        # The view updates at most four times per second. The perception core
        # still runs for every completed 100 ms scan.
        if host_ns - self.last_mesh_ns < 250_000_000:
            return
        self.publish(result, host_ns)

    def publish(self, result, host_ns: int):
        blocks = []
        for p in self.scans:
            blocks.append(np.column_stack((p["x"], p["y"], p["z"])))
        pts = np.concatenate(blocks).astype(np.float32)/1000.0
        keep = (np.any(pts != 0, axis=1) &
                (np.abs(pts[:, 0]) <= 5) & (np.abs(pts[:, 1]) <= 4) &
                (pts[:, 2] >= -.5) & (pts[:, 2] <= 3))
        pts = pts[keep]
        if len(pts) < 10:
            return
        vertices, triangles, normals, _, _ = reconstruct(pts, step_deg=1)
        compact = next((d for d in result.detections if d.cells <= 80), None)
        if compact:
            box = [v/1000 for v in (*compact.min_xyz_mm, *compact.max_xyz_mm)]
            target_mm = compact.distance_mm
        else:
            box = [100, 100, 100, 101, 101, 101]
            target_mm = None
        rgb = colors(vertices, box)
        packed = np.column_stack((vertices, normals, rgb)).astype("<f4")
        lines = line_data(box).astype("<f4")
        encode = lambda blob: base64.b64encode(blob).decode("ascii")
        frame = {"vertices": encode(packed.tobytes()),
                 "indices": encode(triangles.astype("<u4").tobytes()),
                 "lines": encode(lines.tobytes())}
        with self.lock:
            self.seq += 1
            self.latest_frame = frame
            self.last_mesh_ns = host_ns
            self.triangles = len(triangles)
            self.target_mm = target_mm

    def status(self):
        now = time.monotonic_ns()
        with self.lock:
            age = None if not self.last_packet_ns else (now-self.last_packet_ns)//1_000_000
            mesh_age = None if not self.last_mesh_ns else (now-self.last_mesh_ns)//1_000_000
            return {"live": age is not None and age <= 150,
                    "packet_age_ms": age, "mesh_age_ms": mesh_age,
                    "packets": self.packets, "bad_packets": self.bad_packets,
                    "scans": self.scan_count, "triangles": self.triangles,
                    "target_mm": self.target_mm}

    def response(self, since: int):
        with self.lock:
            seq = self.seq
            payload = self.latest_frame if seq > since else {}
            response = {"seq": seq, **payload}
        response["status"] = self.status()
        return response

    def receive_loop(self, sock: socket.socket):
        try:
            print(f"MID-360 UDP {self.bind_ip}:{self.udp_port}, source {self.lidar_ip}", flush=True)
            while not self.stop.is_set():
                ready, _, _ = select.select([sock], [], [], .1)
                if not ready:
                    continue
                for _ in range(512):
                    try:
                        payload, addr = sock.recvfrom(65535)
                    except BlockingIOError:
                        break
                    if addr[0] == self.lidar_ip:
                        self.ingest_packet(payload, time.monotonic_ns())
        finally:
            sock.close()


def make_handler(twin: LiveTwin):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            parsed = urlparse(self.path)
            if parsed.path == "/":
                body = PAGE.encode("utf-8")
                mime = "text/html; charset=utf-8"
            elif parsed.path == "/frame":
                try:
                    since = int(parse_qs(parsed.query).get("since", ["0"])[0])
                except ValueError:
                    since = 0
                body = json.dumps(twin.response(since), separators=(",", ":")).encode("utf-8")
                mime = "application/json; charset=utf-8"
            elif parsed.path == "/health":
                body = json.dumps(twin.status()).encode("utf-8")
                mime = "application/json; charset=utf-8"
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def log_message(self, *_):
            pass

    return Handler


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lidar-ip", required=True)
    ap.add_argument("--bind-ip", default="0.0.0.0")
    ap.add_argument("--udp-port", type=int, default=56301)
    ap.add_argument("--http-port", type=int, default=8765)
    ap.add_argument("--window-scans", type=int, default=3)
    args = ap.parse_args()
    if not 1 <= args.window_scans <= 5:
        ap.error("--window-scans must be 1..5")
    twin = LiveTwin(args.lidar_ip, args.bind_ip, args.udp_port, args.window_scans)
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8*1024*1024)
    try:
        udp.bind((args.bind_ip, args.udp_port))
        udp.setblocking(False)
        http = ThreadingHTTPServer(("127.0.0.1", args.http_port), make_handler(twin))
    except Exception:
        udp.close()
        raise
    worker = threading.Thread(target=twin.receive_loop, args=(udp,), daemon=True)
    worker.start()
    print(f"Live viewer: http://127.0.0.1:{args.http_port}/", flush=True)
    try:
        http.serve_forever(poll_interval=.2)
    except KeyboardInterrupt:
        pass
    finally:
        twin.stop.set()
        http.server_close()
        worker.join(timeout=2)


if __name__ == "__main__":
    main()
