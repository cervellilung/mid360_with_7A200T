"""Render a measured MID-360 scene as a PNG and standalone orbitable HTML.

This is an offline visualization. It may combine scans from a stationary
recording; the realtime integer perception path remains single-scan.
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


HTML = r"""<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>MID-360 实测点云场景</title><style>
html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#08111b;color:#e8f1f8;font:14px system-ui,Segoe UI,sans-serif}
canvas{display:block;width:100vw;height:100vh;cursor:grab}canvas:active{cursor:grabbing}
.panel{position:absolute;left:20px;top:18px;background:#0d1b2bcf;border:1px solid #3b5368;border-radius:12px;padding:14px 18px;max-width:370px;backdrop-filter:blur(7px);line-height:1.65}
.panel h1{font-size:18px;margin:0 0 5px}.tag{display:inline-block;padding:2px 8px;border-radius:20px;background:#143e4a;color:#8ce8e4;font-size:12px;margin-bottom:5px}
.legend{margin-top:7px;color:#b8c9d5}.dot{display:inline-block;width:10px;height:10px;border-radius:50%;margin-right:6px}.btn{background:#15384c;color:#e8f1f8;border:1px solid #5a7c8d;border-radius:7px;padding:5px 10px;cursor:pointer;margin-top:8px}
.footer{position:absolute;right:18px;bottom:14px;background:#0d1b2bcf;border:1px solid #3b5368;border-radius:8px;padding:8px 12px;color:#c1d4df}
</style></head><body><canvas id="scene"></canvas><div class="panel"><span class="tag">MID-360 · 真实录制</span><h1>雷达点云场景预览</h1>
<div>采样点：<b>__NPOINTS__</b> · 采集：<b>__NSCANS__</b> 个扫描桶</div>
<div>橙色：检测到的左前方箱子可见范围</div><div>雷达原点到箱子最近点：<b>__DISTANCE__ m</b>（水平）</div>
<div class="legend"><span class="dot" style="background:#ffae45"></span>箱子点云　<span class="dot" style="background:#72b9d9"></span>其他实测回波</div>
<div class="legend">拖动旋转 · 滚轮缩放 · 双击复位</div><button class="btn" id="reset">复位视角</button>
<div class="legend">表面由实测点表示；空白处没有补建几何。坐标原点在雷达内部，未做车体标定。</div></div>
<div class="footer">前方 +X · 左侧 +Y · 高度 +Z　|　静止录制，多帧累积仅用于场景预览</div>
<script>
const raw=atob('__POINTS__'); const b=new Uint8Array(raw.length);for(let i=0;i<raw.length;i++)b[i]=raw.charCodeAt(i);
const a=new Int16Array(b.buffer); const points=[];
const box=__BOX__; for(let i=0;i<a.length;i+=3){let x=a[i]/100,y=a[i+1]/100,z=a[i+2]/100;
 points.push([x,y,z,x>=box[0]&&x<=box[3]&&y>=box[1]&&y<=box[4]&&z>=box[2]&&z<=box[5]]);}
const cv=document.getElementById('scene'),ctx=cv.getContext('2d');let yaw=-2.40,pitch=.53,radius=9.3;
const target=[.8,0,.7];let dragging=false,lastX=0,lastY=0,scheduled=false;
function resize(){let d=window.devicePixelRatio||1;cv.width=Math.round(innerWidth*d);cv.height=Math.round(innerHeight*d);ctx.setTransform(d,0,0,d,0,0);render();}
function norm(v){let n=Math.hypot(...v);return v.map(x=>x/n)}
function dot(a,b){return a[0]*b[0]+a[1]*b[1]+a[2]*b[2]}
function cross(a,b){return [a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]]}
function render(){scheduled=false;let w=innerWidth,h=innerHeight;ctx.fillStyle='#08111b';ctx.fillRect(0,0,w,h);
 let cam=[target[0]+radius*Math.cos(pitch)*Math.cos(yaw),target[1]+radius*Math.cos(pitch)*Math.sin(yaw),target[2]+radius*Math.sin(pitch)];
 let fwd=norm(target.map((v,i)=>v-cam[i])),right=norm(cross(fwd,[0,0,1])),up=cross(right,fwd),f=Math.min(w*1.1,h*1.25),cx=w*.52,cy=h*.54;
 function proj(p){let v=p.map((x,i)=>x-cam[i]),d=dot(v,fwd);if(d<=.1)return null;return [cx+f*dot(v,right)/d,cy-f*dot(v,up)/d,d]}
 function line(p,q,color,width=1){let A=proj(p),B=proj(q);if(!A||!B)return;ctx.strokeStyle=color;ctx.lineWidth=width;ctx.beginPath();ctx.moveTo(A[0],A[1]);ctx.lineTo(B[0],B[1]);ctx.stroke()}
 for(let x=-2;x<=5;x++){line([x,-3,0],[x,3,0],'#183042')}
 for(let y=-3;y<=3;y++){line([-2,y,0],[5,y,0],'#183042')}
 let projected=[];for(const p of points){let q=proj(p);if(q)projected.push([q[0],q[1],q[2],p[3],p[2]])}
 projected.sort((a,b)=>b[2]-a[2]);for(const p of projected){if(p[0]<0||p[0]>=w||p[1]<0||p[1]>=h)continue;
  ctx.fillStyle=p[3]?'#ffad45':p[4]<.15?'#3c7592':p[4]<1?'#76b9d7':'#bfd4e1';
  let s=p[3]?2.6:1.25;ctx.fillRect(p[0],p[1],s,s)}
 const corners=[];for(let i=0;i<8;i++)corners.push([i&1?box[3]:box[0],i&2?box[4]:box[1],i&4?box[5]:box[2]]);
 for(const [i,j] of [[0,1],[0,2],[0,4],[1,3],[1,5],[2,3],[2,6],[3,7],[4,5],[4,6],[5,7],[6,7]])line(corners[i],corners[j],'#ffd384',1.5);
 line([0,0,0],[.7,0,0],'#ff6278',3);line([0,0,0],[0,.7,0],'#55e0a7',3);line([0,0,0],[0,0,.7],'#76b8ff',3);
 for(const [pos,label,color] of [[[.8,0,0],'FRONT +X','#ff8393'],[[0,.8,0],'LEFT +Y','#74f0b7'],[[0,0,.8],'UP +Z','#9acbff'],[[0,0,0],'RADAR','#ffffff']]){let q=proj(pos);if(q){ctx.font='bold 13px Segoe UI, sans-serif';ctx.fillStyle=color;ctx.fillText(label,q[0]+6,q[1]-6)}}
 let q=proj([(box[0]+box[3])/2,(box[1]+box[4])/2,box[5]+.18]);if(q){ctx.fillStyle='#ffd384';ctx.font='bold 16px Segoe UI, sans-serif';ctx.fillText('BOX · LEFT FRONT',q[0],q[1])}}
function schedule(){if(!scheduled){scheduled=true;requestAnimationFrame(render)}}
cv.addEventListener('pointerdown',e=>{dragging=true;lastX=e.clientX;lastY=e.clientY;cv.setPointerCapture(e.pointerId)});
cv.addEventListener('pointermove',e=>{if(!dragging)return;yaw+=(e.clientX-lastX)*.006;pitch=Math.max(.05,Math.min(1.45,pitch+(e.clientY-lastY)*.006));lastX=e.clientX;lastY=e.clientY;schedule()});
cv.addEventListener('pointerup',()=>dragging=false);cv.addEventListener('wheel',e=>{e.preventDefault();radius=Math.max(3,Math.min(20,radius*Math.exp(e.deltaY*.001)));schedule()},{passive:false});
function reset(){yaw=-2.40;pitch=.53;radius=9.3;schedule()}cv.addEventListener('dblclick',reset);document.getElementById('reset').onclick=reset;window.addEventListener('resize',resize);resize();
</script></body></html>"""


def voxel_sample(points: np.ndarray, voxel_mm: int) -> np.ndarray:
    keys = np.floor_divide(points, voxel_mm)
    _, indices = np.unique(keys, axis=0, return_index=True)
    return points[np.sort(indices)]


def camera_basis():
    camera = np.array([-5.2, -5.6, 4.1], dtype=np.float64)
    target = np.array([0.8, 0.0, 0.7])
    forward = target - camera
    forward /= np.linalg.norm(forward)
    right = np.cross(forward, [0, 0, 1])
    right /= np.linalg.norm(right)
    up = np.cross(right, forward)
    return camera, forward, right, up


def render_png(points: np.ndarray, box: list[float], distance_m: float, out: Path):
    width, height = 1800, 980
    img = np.full((height, width, 3), (27, 18, 9), dtype=np.uint8)
    cv2.rectangle(img, (25, 80), (1085, 945), (42, 34, 19), 1)
    cv2.rectangle(img, (1100, 80), (1775, 945), (42, 34, 19), 1)
    camera, forward, right, up = camera_basis()

    def perspective(p):
        v = np.asarray(p, dtype=float) - camera
        depth = np.dot(v, forward)
        if depth <= 0.1:
            return None
        return int(570 + 810*np.dot(v, right)/depth), int(540 - 810*np.dot(v, up)/depth), depth

    for x in range(-2, 6):
        p, q = perspective((x, -3, 0)), perspective((x, 3, 0))
        cv2.line(img, p[:2], q[:2], (54, 43, 28), 1, cv2.LINE_AA)
    for y in range(-3, 4):
        p, q = perspective((-2, y, 0)), perspective((5, y, 0))
        cv2.line(img, p[:2], q[:2], (54, 43, 28), 1, cv2.LINE_AA)

    xyz = points.astype(np.float64) / 1000
    v = xyz - camera
    depth = v @ forward
    good = depth > 0.1
    xyz, v, depth = xyz[good], v[good], depth[good]
    uv = np.column_stack((570 + 810*(v @ right)/depth,
                          540 - 810*(v @ up)/depth)).astype(np.int32)
    is_box = ((xyz[:, 0] >= box[0]) & (xyz[:, 0] <= box[3]) &
              (xyz[:, 1] >= box[1]) & (xyz[:, 1] <= box[4]) &
              (xyz[:, 2] >= box[2]) & (xyz[:, 2] <= box[5]))
    for i in np.argsort(-depth):
        u, vv = uv[i]
        if 35 <= u < 1075 and 90 <= vv < 930:
            color = ((76, 171, 255) if is_box[i] else
                     (147, 108, 48) if xyz[i, 2] < 0.15 else
                     (212, 164, 95) if xyz[i, 2] < 1 else (226, 210, 176))
            cv2.circle(img, (int(u), int(vv)), 2 if is_box[i] else 1, color, -1, cv2.LINE_AA)

    corners = [[box[3] if i & 1 else box[0],
                box[4] if i & 2 else box[1],
                box[5] if i & 4 else box[2]] for i in range(8)]
    for i, j in ((0, 1), (0, 2), (0, 4), (1, 3), (1, 5), (2, 3),
                 (2, 6), (3, 7), (4, 5), (4, 6), (5, 7), (6, 7)):
        p, q = perspective(corners[i]), perspective(corners[j])
        cv2.line(img, p[:2], q[:2], (122, 206, 255), 2, cv2.LINE_AA)
    for end, color, label in [((0.8, 0, 0), (100, 100, 255), "FRONT +X"),
                              ((0, 0.8, 0), (170, 224, 78), "LEFT +Y"),
                              ((0, 0, 0.8), (255, 183, 109), "UP +Z")]:
        p, q = perspective((0, 0, 0)), perspective(end)
        cv2.arrowedLine(img, p[:2], q[:2], color, 3, cv2.LINE_AA, tipLength=.15)
        cv2.putText(img, label, (q[0]+5, q[1]-5), cv2.FONT_HERSHEY_SIMPLEX, .47, color, 1, cv2.LINE_AA)

    # BEV: +X up, +Y left. This complements the oblique point cloud.
    def bev(x, y):
        return int(1438-y*100), int(660-x*100)
    for x in range(-2, 6):
        cv2.line(img, bev(x, -3), bev(x, 3), (54, 43, 28), 1, cv2.LINE_AA)
    for y in range(-3, 4):
        cv2.line(img, bev(-2, y), bev(5, y), (54, 43, 28), 1, cv2.LINE_AA)
    for p, marked in zip(xyz, is_box):
        u, vv = bev(p[0], p[1])
        if 1110 <= u < 1765 and 115 <= vv < 930:
            cv2.circle(img, (u, vv), 2 if marked else 1,
                       (76, 171, 255) if marked else (166, 127, 69), -1)
    cv2.rectangle(img, bev(box[0], box[1]), bev(box[3], box[4]), (122, 206, 255), 2)
    ru, rv = bev(0, 0)
    cv2.circle(img, (ru, rv), 7, (240, 241, 242), -1, cv2.LINE_AA)
    cv2.putText(img, "RADAR", (ru+10, rv+5), cv2.FONT_HERSHEY_SIMPLEX, .50, (240, 241, 242), 1, cv2.LINE_AA)
    cv2.putText(img, "FRONT +X", (1420, 115), cv2.FONT_HERSHEY_SIMPLEX, .62, (230, 226, 213), 2, cv2.LINE_AA)
    cv2.putText(img, "LEFT +Y", (1120, 900), cv2.FONT_HERSHEY_SIMPLEX, .52, (170, 224, 78), 1, cv2.LINE_AA)
    cv2.putText(img, "RIGHT -Y", (1625, 900), cv2.FONT_HERSHEY_SIMPLEX, .52, (170, 224, 78), 1, cv2.LINE_AA)
    cv2.putText(img, "MID-360  |  MEASURED SCENE PREVIEW", (32, 43),
                cv2.FONT_HERSHEY_SIMPLEX, .78, (245, 238, 221), 2, cv2.LINE_AA)
    cv2.putText(img, f"BOX (LEFT FRONT)  |  NEAREST {distance_m:.2f} m", (1130, 51),
                cv2.FONT_HERSHEY_SIMPLEX, .56, (122, 206, 255), 2, cv2.LINE_AA)
    cv2.putText(img, "Oblique view - observed points only", (45, 925),
                cv2.FONT_HERSHEY_SIMPLEX, .52, (174, 181, 183), 1, cv2.LINE_AA)
    cv2.putText(img, "Top-down view", (1120, 925),
                cv2.FONT_HERSHEY_SIMPLEX, .52, (174, 181, 183), 1, cv2.LINE_AA)
    if not cv2.imwrite(str(out), img):
        raise RuntimeError(f"failed to write {out}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--session", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    assembler = FrameAssembler()
    all_points = []
    last_scan = None
    scans = 0
    for event in SessionReader(args.session):
        if event.kind != RADAR:
            continue
        packet = decode_mid360(event.payload, event.host_ns)
        all_points.append(np.column_stack((packet.points["x"],
                                            packet.points["y"],
                                            packet.points["z"])))
        if scan := assembler.add(packet):
            last_scan = scan
            scans += 1
    if last_scan is None:
        raise ValueError("recording has no closed scan")
    detections = GridProcessor().process(last_scan.points).detections
    candidates = [d for d in detections if d.closest_xyz_mm[0] > 0 and d.closest_xyz_mm[1] > 0]
    if not candidates:
        raise ValueError("no left-front detection in the last closed scan")
    target = min(candidates, key=lambda d: d.nearest_xy_sq_mm2)
    box = [v/1000 for v in (*target.min_xyz_mm, *target.max_xyz_mm)]
    points = np.concatenate(all_points)
    keep = ((points[:, 0] != 0) | (points[:, 1] != 0) | (points[:, 2] != 0))
    keep &= ((points[:, 0] >= -3000) & (points[:, 0] <= 5000) &
             (np.abs(points[:, 1]) <= 3500) &
             (points[:, 2] >= -500) & (points[:, 2] <= 3000))
    sampled = voxel_sample(points[keep], 50)
    distance_m = target.distance_mm/1000
    png = args.out / "scene_preview.png"
    render_png(sampled, box, distance_m, png)
    interactive = sampled[::2]
    packed = np.round(interactive/10).astype("<i2").tobytes()
    html = (HTML.replace("__POINTS__", base64.b64encode(packed).decode("ascii"))
            .replace("__BOX__", json.dumps(box))
            .replace("__NPOINTS__", f"{len(interactive):,}")
            .replace("__NSCANS__", str(scans))
            .replace("__DISTANCE__", f"{distance_m:.2f}"))
    (args.out / "scene_interactive.html").write_text(html, encoding="utf-8")
    info = {"source": str(args.session), "scans": scans,
            "preview_points": len(sampled), "interactive_points": len(interactive),
            "nearest_distance_m": distance_m, "visible_bbox_m": box,
            "note": "Static LiDAR point-cloud preview, not a reconstructed solid model."}
    (args.out / "scene_info.json").write_text(json.dumps(info, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(info, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
