"""Loopback-only real-data experiment viewer and bounded re-computation API."""
import argparse
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
import json
from pathlib import Path
import subprocess
import sys
import threading
from urllib.parse import unquote, urlsplit
import uuid
import webbrowser

ROOT=Path(__file__).resolve().parents[2]


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--port',type=int,default=8890)
    ap.add_argument('--output',type=Path,default=ROOT/'sample/car_showcase/planar_corridor_6m')
    ap.add_argument('--no-browser',action='store_true')
    args=ap.parse_args(); output=args.output.resolve(); ui=ROOT/'user_app/car_showcase'
    if not (output/'manifest.json').exists(): ap.error('Generate the real experiment cache first')
    manifest=json.loads((output/'manifest.json').read_text(encoding='utf-8'))
    cfg=manifest.get('config',{})
    max_range=float(cfg.get('max_range',12))
    if not 0<max_range<=6: ap.error('Preview cache must use a reconstruction range of at most 6 m; rebuild it first')
    recording=manifest.get('source')
    lock=threading.Lock(); job={'state':'idle'}
    def run(command,path):
        try:
            done=subprocess.run(command,cwd=ROOT,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            with lock: job.update(state='done' if done.returncode==0 else 'failed',exit=done.returncode,manifest=f'output/jobs/{path.name}/manifest.json')
        except OSError as exc:
            with lock: job.update(state='failed',error=str(exc))
    class Handler(SimpleHTTPRequestHandler):
        def log_message(self,*a): pass
        def translate_path(self,path):
            path=unquote(urlsplit(path).path)
            base,relative=(output,path[8:]) if path.startswith('/output/') else (ui,path.lstrip('/') or 'planar_viewer.html')
            target=(base/relative).resolve()
            return str(target if target.is_relative_to(base.resolve()) else ui/'__missing__')
        def answer(self,data,status=200):
            body=json.dumps(data).encode();self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
        def do_GET(self):
            if self.path=='/api/status':
                with lock: self.answer(dict(job))
            else: super().do_GET()
        def do_POST(self):
            if self.path!='/api/rebuild': self.answer({'error':'unknown endpoint'},404);return
            origin=self.headers.get('Origin')
            if origin not in (None,f'http://127.0.0.1:{args.port}',f'http://localhost:{args.port}'):
                self.answer({'error':'origin rejected'},403);return
            try:
                length=int(self.headers.get('Content-Length','0'))
                if not 0<length<=1024: raise ValueError('Invalid body size')
                data=json.loads(self.rfile.read(length)); allowed={'time','plane_mm','connection_scale','hole_radius','max_angle'}
                if set(data)!=allowed: raise ValueError('Expected fixed parameter keys')
                ranges={'time':(.2,15),'plane_mm':(5,40),'connection_scale':(1.5,4),'hole_radius':(.02,.4),'max_angle':(.8,3.2)}
                import math
                for key,(lo,hi) in ranges.items():
                    data[key]=float(data[key])
                    if not math.isfinite(data[key]) or not lo<=data[key]<=hi:raise ValueError('Parameter outside allowed range: '+key)
            except (ValueError,TypeError,json.JSONDecodeError) as exc:
                self.answer({'error':str(exc)},400);return
            with lock:
                if job['state']=='running':self.answer({'error':'Rebuild already running'},409);return
                path=output/'jobs'/uuid.uuid4().hex
                command=[sys.executable,str(ROOT/'tools/run_build.py'),'--name','Python_planar_recompute','--kind','python','--estimate','45','--log',str(path/'experiment.log'),'--',sys.executable,'-m','web_server.car_showcase.build_planar_experiment','--recording',recording,'--out',str(path),'--times',str(data['time']),'--plane-mm',str(data['plane_mm']),'--connection-scale',str(data['connection_scale']),'--hole-radius',str(data['hole_radius']),'--max-angle',str(data['max_angle']),'--max-range',str(max_range),'--skip-holdout']
                job.clear();job.update(state='running',parameters=data)
                threading.Thread(target=run,args=(command,path),daemon=True).start();self.answer(dict(job),202)
    server=ThreadingHTTPServer(('127.0.0.1',args.port),Handler)
    url=f'http://127.0.0.1:{args.port}/planar_viewer.html';print(url,flush=True)
    if not args.no_browser:webbrowser.open(url)
    try:server.serve_forever()
    except KeyboardInterrupt:pass
    finally:server.server_close()


if __name__=='__main__':main()
