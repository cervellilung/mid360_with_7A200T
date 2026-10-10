"""Offline range-image surface reconstruction of one stationary MID-360 session.

Only measured line-of-sight surfaces and very small supported gaps are meshed.
This is a visual approximation, not a watertight or metrically certified CAD
model. The realtime FPGA reference algorithm is not affected.
"""

from __future__ import annotations

import argparse
import base64
import json
from pathlib import Path

import cv2
import numpy as np

from pc_perception.frame import FrameAssembler
from pc_perception.grid import GridProcessor
from pc_perception.protocol import decode_mid360
from pc_perception.session import RADAR, SessionReader


HTML = r"""<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>MID-360 场景表面重建</title><style>
html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#07121c;color:#eaf3f7;font:14px system-ui,Segoe UI,sans-serif}
canvas{display:block;width:100vw;height:100vh;cursor:grab}canvas:active{cursor:grabbing}
.panel{position:absolute;left:18px;top:18px;max-width:380px;background:#0c1c2ddd;border:1px solid #466078;border-radius:12px;padding:15px 18px;line-height:1.6;backdrop-filter:blur(8px)}
h1{font-size:19px;margin:0 0 7px}.small{font-size:12px;color:#b4c7d3;margin-top:8px}.tag{display:inline-block;color:#8aebd5;background:#164748;border-radius:20px;padding:2px 9px;font-size:12px}
button{background:#173a4b;border:1px solid #688da0;color:white;border-radius:7px;padding:6px 10px;margin-top:9px;cursor:pointer}
.foot{position:absolute;right:18px;bottom:15px;background:#0c1c2ddd;border:1px solid #466078;border-radius:8px;padding:8px 12px}
</style></head><body><canvas id="view"></canvas><div class="panel"><span class="tag">MID-360 · 全场景回波</span><h1>静止场景表面近似重建</h1>
<div>三角面：<b>__TRIANGLES__</b>　扫描桶：<b>__SCANS__</b></div>
<div>橙色区域：左前方纸箱 · 最近水平距离 <b>__DISTANCE__ m</b></div>
<div>蓝灰色区域：地面、防护网及其他可见表面</div>
<div class="small">拖动旋转，滚轮缩放，双击复位。可用按钮切换线框，以查看曲面由哪些小三角面组成。</div>
<button id="reset">复位视角</button> <button id="wire">显示线框</button>
<div class="small">这是从雷达可见回波生成的平滑近似表面。防护网孔洞、遮挡背面和没有测到的物体细节无法还原；亮橙线框是算法输出的箱子可见范围。</div></div>
<div class="foot">前方 +X　左侧 +Y　高度 +Z　|　离线静止录制</div>
<script>
function bytes(s){let t=atob(s),a=new Uint8Array(t.length);for(let i=0;i<t.length;i++)a[i]=t.charCodeAt(i);return a}
const vertices=new Float32Array(bytes('__VERTICES__').buffer),indices=new Uint32Array(bytes('__INDICES__').buffer),wireIndices=new Uint32Array(bytes('__WIREINDICES__').buffer);
const lines=new Float32Array(bytes('__LINES__').buffer),box=__BOX__;
const cv=document.getElementById('view'),gl=cv.getContext('webgl2',{antialias:true,depth:true});
if(!gl){document.querySelector('h1').textContent='浏览器不支持 WebGL2，请查看 PNG 预览';throw new Error('WebGL2 unavailable')}
const vs=`#version 300 es
precision highp float;layout(location=0) in vec3 a_pos;layout(location=1) in vec3 a_normal;layout(location=2) in vec3 a_color;
uniform vec3 u_cam,u_forward,u_right,u_up;uniform float u_focal,u_aspect,u_near,u_far;out vec3 v_normal,v_color;
void main(){vec3 rel=a_pos-u_cam;float d=dot(rel,u_forward);float A=(u_far+u_near)/(u_far-u_near);float B=-2.0*u_far*u_near/(u_far-u_near);
gl_Position=vec4(dot(rel,u_right)*u_focal/u_aspect,dot(rel,u_up)*u_focal,A*d+B,d);v_normal=a_normal;v_color=a_color;}`;
const fs=`#version 300 es
precision highp float;in vec3 v_normal,v_color;uniform bool u_line;out vec4 out_color;
void main(){float light=abs(dot(normalize(v_normal),normalize(vec3(-0.45,-0.35,0.83))));float shade=u_line?1.0:(0.46+0.54*light);out_color=vec4(v_color*shade,1.0);}`;
function shader(type,src){let s=gl.createShader(type);gl.shaderSource(s,src);gl.compileShader(s);if(!gl.getShaderParameter(s,gl.COMPILE_STATUS))throw new Error(gl.getShaderInfoLog(s));return s}
let prog=gl.createProgram();gl.attachShader(prog,shader(gl.VERTEX_SHADER,vs));gl.attachShader(prog,shader(gl.FRAGMENT_SHADER,fs));gl.linkProgram(prog);
if(!gl.getProgramParameter(prog,gl.LINK_STATUS))throw new Error(gl.getProgramInfoLog(prog));gl.useProgram(prog);
const loc={};for(const n of ['u_cam','u_forward','u_right','u_up','u_focal','u_aspect','u_near','u_far','u_line'])loc[n]=gl.getUniformLocation(prog,n);
function geometry(data,index){let vao=gl.createVertexArray();gl.bindVertexArray(vao);let vb=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,vb);gl.bufferData(gl.ARRAY_BUFFER,data,gl.STATIC_DRAW);
for(let i=0;i<3;i++){gl.enableVertexAttribArray(i);gl.vertexAttribPointer(i,3,gl.FLOAT,false,36,i*12)}
let ib=null;if(index){ib=gl.createBuffer();gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER,ib);gl.bufferData(gl.ELEMENT_ARRAY_BUFFER,index,gl.STATIC_DRAW)}return vao}
const mesh=geometry(vertices,indices),wireMesh=geometry(vertices,wireIndices),edges=geometry(lines,null);let yaw=-2.4,pitch=.45,radius=2.7,showWire=false,drag=false,lastX=0,lastY=0,frame=false;
const target=[1,.2,.6];function norm(v){let n=Math.hypot(...v);return v.map(x=>x/n)}function cross(a,b){return [a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]]}
function render(){frame=false;let d=devicePixelRatio||1,w=Math.round(innerWidth*d),h=Math.round(innerHeight*d);if(cv.width!==w||cv.height!==h){cv.width=w;cv.height=h}gl.viewport(0,0,w,h);
gl.clearColor(.027,.071,.11,1);gl.clear(gl.COLOR_BUFFER_BIT|gl.DEPTH_BUFFER_BIT);gl.enable(gl.DEPTH_TEST);gl.disable(gl.CULL_FACE);
let cam=[target[0]+radius*Math.cos(pitch)*Math.cos(yaw),target[1]+radius*Math.cos(pitch)*Math.sin(yaw),target[2]+radius*Math.sin(pitch)],f=norm(target.map((v,i)=>v-cam[i])),r=norm(cross(f,[0,0,1])),u=cross(r,f);
for(const [n,v] of [['u_cam',cam],['u_forward',f],['u_right',r],['u_up',u]])gl.uniform3fv(loc[n],v);
gl.uniform1f(loc.u_focal,1.75);gl.uniform1f(loc.u_aspect,w/h);gl.uniform1f(loc.u_near,.05);gl.uniform1f(loc.u_far,50);
gl.uniform1i(loc.u_line,0);gl.bindVertexArray(mesh);gl.drawElements(gl.TRIANGLES,indices.length,gl.UNSIGNED_INT,0);
gl.uniform1i(loc.u_line,1);gl.bindVertexArray(edges);gl.lineWidth(2);gl.drawArrays(gl.LINES,0,lines.length/9);
if(showWire){gl.disable(gl.DEPTH_TEST);gl.bindVertexArray(wireMesh);gl.drawElements(gl.LINES,wireIndices.length,gl.UNSIGNED_INT,0);gl.enable(gl.DEPTH_TEST)}}
function schedule(){if(!frame){frame=true;requestAnimationFrame(render)}}
cv.addEventListener('pointerdown',e=>{drag=true;lastX=e.clientX;lastY=e.clientY;cv.setPointerCapture(e.pointerId)});
cv.addEventListener('pointermove',e=>{if(!drag)return;yaw+=(e.clientX-lastX)*.006;pitch=Math.max(.04,Math.min(1.45,pitch+(e.clientY-lastY)*.006));lastX=e.clientX;lastY=e.clientY;schedule()});
cv.addEventListener('pointerup',()=>drag=false);cv.addEventListener('wheel',e=>{e.preventDefault();radius=Math.max(2.5,Math.min(25,radius*Math.exp(e.deltaY*.001)));schedule()},{passive:false});
function reset(){yaw=-2.4;pitch=.45;radius=2.7;schedule()}cv.addEventListener('dblclick',reset);document.getElementById('reset').onclick=reset;
document.getElementById('wire').onclick=()=>{showWire=!showWire;document.getElementById('wire').textContent=showWire?'隐藏线框':'显示线框';schedule()};window.addEventListener('resize',schedule);render();
</script></body></html>"""


def points_and_last_scan(session: Path):
    assembler = FrameAssembler()
    blocks = []
    last = None
    scans = 0
    for event in SessionReader(session):
        if event.kind != RADAR:
            continue
        packet = decode_mid360(event.payload, event.host_ns)
        p = packet.points
        blocks.append(np.column_stack((p["x"], p["y"], p["z"])))
        if scan := assembler.add(packet):
            last = scan
            scans += 1
    if last is None:
        raise ValueError("no closed scan")
    pts = np.concatenate(blocks).astype(np.float32)/1000.0
    keep = (np.any(pts != 0, axis=1) &
            (np.abs(pts[:, 0]) <= 5) & (np.abs(pts[:, 1]) <= 4) &
            (pts[:, 2] >= -.5) & (pts[:, 2] <= 3))
    return pts[keep], last, scans


def reconstruct(points: np.ndarray, step_deg: float = .5):
    # Select a stable near surface per angular cell. Occluded rear surfaces
    # cannot be inferred from a single stationary viewpoint.
    xy = np.hypot(points[:, 0], points[:, 1])
    r = np.hypot(xy, points[:, 2])
    az = np.degrees(np.arctan2(points[:, 1], points[:, 0]))
    el = np.degrees(np.arctan2(points[:, 2], xy))
    naz = int(round(360/step_deg))
    nel = int(round(65/step_deg))  # -10..55 degrees
    ia = np.floor((az+180)/step_deg).astype(np.int32)
    ie = np.floor((el+10)/step_deg).astype(np.int32)
    good = (ia>=0)&(ia<naz)&(ie>=0)&(ie<nel)&(r>.25)
    ia, ie, r = ia[good], ie[good], r[good]
    linear = ia*nel+ie
    order = np.lexsort((r, linear))
    unique, start, count = np.unique(linear[order], return_index=True, return_counts=True)
    pick = order[start + np.floor((count-1)*.25).astype(np.int64)]
    ranges = np.zeros(naz*nel, np.float32)
    ranges[unique] = r[pick]
    ranges = ranges.reshape(naz, nel)
    measured = ranges > 0

    # Fill only a one-cell hole whose surrounding measurements agree in depth.
    # The recorded net has larger holes, which remain unmeshed.
    filled = ranges.copy()
    n = np.zeros_like(ranges, np.int16)
    total = np.zeros_like(ranges)
    lo = np.full_like(ranges, np.inf)
    hi = np.zeros_like(ranges)
    for da in (-1, 0, 1):
        for de in (-1, 0, 1):
            if da == 0 and de == 0:
                continue
            shifted = np.roll(ranges, da, axis=0)
            shifted = np.roll(shifted, de, axis=1)
            if de > 0:
                shifted[:, :de] = 0
            elif de < 0:
                shifted[:, de:] = 0
            m = shifted > 0
            n += m
            total += shifted
            lo = np.minimum(lo, np.where(m, shifted, np.inf))
            hi = np.maximum(hi, shifted)
    hole = (~measured)&(n>=5)&((hi-lo)<.18)
    filled[hole] = total[hole]/n[hole]

    # A small edge-preserving range average softens measurement quantization.
    smoothed = filled.copy()
    weight = np.ones_like(filled)
    accum = filled.copy()
    for da, de in ((-1, 0), (1, 0), (0, -1), (0, 1)):
        neighbor = np.roll(np.roll(filled, da, axis=0), de, axis=1)
        if de > 0:
            neighbor[:, :de] = 0
        elif de < 0:
            neighbor[:, de:] = 0
        similar = (filled>0)&(neighbor>0)&(np.abs(filled-neighbor)<.12)
        accum += np.where(similar, neighbor*.35, 0)
        weight += similar*.35
    smoothed[filled>0] = accum[filled>0]/weight[filled>0]

    ai, ei = np.nonzero(smoothed>0)
    azrad = np.radians(-180+(ai+.5)*step_deg)
    elrad = np.radians(-10+(ei+.5)*step_deg)
    rr = smoothed[ai, ei]
    vertices = np.column_stack((rr*np.cos(elrad)*np.cos(azrad),
                                rr*np.cos(elrad)*np.sin(azrad),
                                rr*np.sin(elrad))).astype(np.float32)
    index = np.full((naz, nel), -1, np.int32)
    index[ai, ei] = np.arange(len(vertices), dtype=np.int32)

    # Connect only adjacent angular samples with a short Euclidean edge.
    tris = []
    for da, de, dc in ((0, 0, 1), (1, 0, 2)):
        a = index[:naz-1, :nel-1]
        b = index[1:, :nel-1]
        c = index[:naz-1, 1:]
        d = index[1:, 1:]
        tri = np.stack((a, b, c), axis=-1) if dc == 1 else np.stack((d, c, b), axis=-1)
        valid = np.all(tri>=0, axis=-1)
        candidate = tri[valid]
        if len(candidate):
            p = vertices[candidate]
            edge = np.maximum.reduce((np.linalg.norm(p[:, 0]-p[:, 1], axis=1),
                                      np.linalg.norm(p[:, 0]-p[:, 2], axis=1),
                                      np.linalg.norm(p[:, 1]-p[:, 2], axis=1)))
            depth = np.linalg.norm(p.mean(axis=1), axis=1)
            tris.append(candidate[edge < .12+.035*depth])
    triangles = np.concatenate(tris).astype(np.uint32)

    # Surface normals face the observed sensor, then average per vertex.
    p = vertices[triangles]
    normal = np.cross(p[:, 1]-p[:, 0], p[:, 2]-p[:, 0])
    flip = np.sum(normal*(-p.mean(axis=1)), axis=1)<0
    triangles[flip, 1], triangles[flip, 2] = triangles[flip, 2].copy(), triangles[flip, 1].copy()
    p = vertices[triangles]
    normal = np.cross(p[:, 1]-p[:, 0], p[:, 2]-p[:, 0])
    norms = np.zeros_like(vertices)
    for k in range(3):
        np.add.at(norms, triangles[:, k], normal)
    norms /= np.maximum(np.linalg.norm(norms, axis=1, keepdims=True), 1e-8)
    return vertices, triangles, norms, int(measured.sum()), int(hole.sum())


def colors(vertices: np.ndarray, box: list[float]):
    z = vertices[:, 2]
    ground = np.clip((z+.1)/1.6, 0, 1)
    c = np.column_stack((.28+.42*ground, .48+.35*ground, .64+.27*ground)).astype(np.float32)
    c[z<.12] = (.24, .41, .50)
    inside = ((vertices[:, 0]>=box[0])&(vertices[:, 0]<=box[3])&
              (vertices[:, 1]>=box[1])&(vertices[:, 1]<=box[4])&
              (vertices[:, 2]>=box[2])&(vertices[:, 2]<=box[5]))
    c[inside] = (.99, .60, .24)
    return c


def line_data(box: list[float]):
    segments = []
    def add(a, b, color):
        for p in (a, b):
            segments.extend((*p, 0, 0, 1, *color))
    for x in range(-2, 6):
        add((x,-3,0),(x,3,0),(.18,.31,.36))
    for y in range(-3, 4):
        add((-2,y,0),(5,y,0),(.18,.31,.36))
    add((0,0,0),(.8,0,0),(1,.28,.34))
    add((0,0,0),(0,.8,0),(.35,.93,.62))
    add((0,0,0),(0,0,.8),(.45,.68,1))
    corners = [[box[3] if i&1 else box[0],box[4] if i&2 else box[1],box[5] if i&4 else box[2]] for i in range(8)]
    for i,j in ((0,1),(0,2),(0,4),(1,3),(1,5),(2,3),(2,6),(3,7),(4,5),(4,6),(5,7),(6,7)):
        add(corners[i],corners[j],(1,.85,.51))
    return np.asarray(segments, np.float32)


def render_png(vertices, triangles, norms, rgb, lines, out: Path, inside: bool = False):
    width,height=1680,940
    img=np.full((height,width,3),(28,18,7),np.uint8)
    camera=np.array([-.5,-1.2,1.8] if inside else [-5.2,-5.6,4.1])
    target=np.array([1,.2,.6] if inside else [.8,0,.7])
    forward=target-camera;forward/=np.linalg.norm(forward)
    right=np.cross(forward,[0,0,1]);right/=np.linalg.norm(right)
    up=np.cross(right,forward)
    rel=vertices-camera
    depth=rel@forward
    focal=720 if inside else 900
    uv=np.column_stack((width*.54+focal*(rel@right)/depth,
                        height*.55-focal*(rel@up)/depth)).astype(np.int32)
    light=np.array([-.45,-.35,.83]);light/=np.linalg.norm(light)
    tri_depth=depth[triangles].mean(axis=1)
    for i in np.argsort(-tri_depth):
        ids=triangles[i]
        if np.any(depth[ids]<=.1):
            continue
        q=uv[ids]
        if q[:,0].max()<0 or q[:,0].min()>=width or q[:,1].max()<0 or q[:,1].min()>=height:
            continue
        normal=norms[ids].mean(axis=0)
        shade=.46+.54*abs(np.dot(normal,light))
        color=np.clip(rgb[ids].mean(axis=0)*shade*255,0,255).astype(np.uint8)
        cv2.fillConvexPoly(img,q,color[::-1].tolist(),lineType=cv2.LINE_AA)
    seg=lines.reshape(-1,9)
    rel=seg[:,:3]-camera
    d=rel@forward
    uv_lines=np.column_stack((width*.54+focal*(rel@right)/d,
                              height*.55-focal*(rel@up)/d)).astype(np.int32)
    for i in range(0,len(seg),2):
        color=(seg[i,6:9]*255).astype(np.uint8)[::-1].tolist()
        cv2.line(img,tuple(uv_lines[i]),tuple(uv_lines[i+1]),color,2 if i>=30 else 1,cv2.LINE_AA)
    cv2.rectangle(img,(25,25),(665,155),(17,34,49),-1)
    title="MID-360 | VIEW FROM SENSOR AREA" if inside else "MID-360 | FULL SCENE SURFACE PREVIEW"
    cv2.putText(img,title,(43,69),cv2.FONT_HERSHEY_SIMPLEX,.75,(237,239,239),2,cv2.LINE_AA)
    cv2.putText(img,"Orange: left-front box | Blue: other measured surfaces",(43,108),cv2.FONT_HERSHEY_SIMPLEX,.55,(177,209,220),1,cv2.LINE_AA)
    cv2.putText(img,"Approximate mesh from stationary scans",(43,139),cv2.FONT_HERSHEY_SIMPLEX,.5,(146,169,178),1,cv2.LINE_AA)
    if not cv2.imwrite(str(out),img):
        raise RuntimeError(f"cannot write {out}")


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--session",required=True,type=Path)
    ap.add_argument("--out",required=True,type=Path)
    args=ap.parse_args()
    args.out.mkdir(parents=True,exist_ok=True)
    points,last,scans=points_and_last_scan(args.session)
    ds=[d for d in GridProcessor().process(last.points).detections if d.closest_xyz_mm[0]>0 and d.closest_xyz_mm[1]>0]
    if not ds:raise ValueError("no left-front target")
    target=min(ds,key=lambda d:d.nearest_xy_sq_mm2)
    box=[v/1000 for v in (*target.min_xyz_mm,*target.max_xyz_mm)]
    vertices,triangles,norms,measured,filled=reconstruct(points)
    rgb=colors(vertices,box)
    lines=line_data(box)
    render_png(vertices,triangles,norms,rgb,lines,args.out/"surface_preview.png")
    render_png(vertices,triangles,norms,rgb,lines,args.out/"surface_inside.png",inside=True)
    interleaved=np.column_stack((vertices,norms,rgb)).astype("<f4")
    wire_pairs=np.concatenate((triangles[:,[0,1]],triangles[:,[1,2]],triangles[:,[2,0]]))
    wire_pairs=np.unique(np.sort(wire_pairs,axis=1),axis=0).astype("<u4")
    html=(HTML.replace("__VERTICES__",base64.b64encode(interleaved.tobytes()).decode("ascii"))
          .replace("__INDICES__",base64.b64encode(triangles.astype("<u4").tobytes()).decode("ascii"))
          .replace("__WIREINDICES__",base64.b64encode(wire_pairs.tobytes()).decode("ascii"))
          .replace("__LINES__",base64.b64encode(lines.astype("<f4").tobytes()).decode("ascii"))
          .replace("__BOX__",json.dumps(box))
          .replace("__TRIANGLES__",f"{len(triangles):,}")
          .replace("__SCANS__",str(scans))
          .replace("__DISTANCE__",f"{target.distance_mm/1000:.2f}"))
    (args.out/"surface_interactive.html").write_text(html,encoding="utf-8")
    with (args.out/"scene_surface.obj").open("w",encoding="ascii") as fh:
        fh.write("# MID-360 observed-surface approximation; metres; not watertight\n")
        for v in vertices:fh.write(f"v {v[0]:.4f} {v[1]:.4f} {v[2]:.4f}\n")
        for n in norms:fh.write(f"vn {n[0]:.4f} {n[1]:.4f} {n[2]:.4f}\n")
        for a,b,c in triangles+1:fh.write(f"f {a}//{a} {b}//{b} {c}//{c}\n")
    info={"source":str(args.session),"scans":scans,"input_points":len(points),
          "measured_angular_cells":measured,"small_filled_cells":filled,
          "mesh_vertices":len(vertices),"mesh_triangles":len(triangles),
          "nearest_box_distance_m":target.distance_mm/1000,"box_visible_bbox_m":box,
          "limitation":"Visible-surface approximation, not a complete watertight digital twin."}
    (args.out/"surface_info.json").write_text(json.dumps(info,ensure_ascii=False,indent=2),encoding="utf-8")
    print(json.dumps(info,ensure_ascii=False,indent=2))


if __name__=="__main__":main()
