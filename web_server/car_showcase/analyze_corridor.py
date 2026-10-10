"""Reproducible offline corridor analysis using the existing surface algorithm."""
import ast, base64, json, argparse
from pathlib import Path
import numpy as np
from scipy import ndimage
from PIL import Image, ImageDraw
from web_server.pc_perception.session import SessionReader
from web_server.pc_perception.protocol import decode_mid360, PacketError
from .mesh import make_mesh
from .assets import pack, write_binary

ROOT=Path(__file__).resolve().parents[2]

def angular(points):
    p=np.asarray(points,dtype=np.float32)/1000
    r=np.linalg.norm(p,axis=1)
    good=np.isfinite(p).all(axis=1)&(r>=.3)&(r<=12)
    p,r=p[good],r[good]
    rows,cols=131,450
    y=np.floor((np.degrees(np.arctan2(p[:,2],np.hypot(p[:,0],p[:,1])))+40)/.8).astype(int)
    x=np.floor((np.degrees(np.arctan2(p[:,1],p[:,0]))+180)/.8).astype(int)
    good=(y>=0)&(y<rows)&(x>=0)&(x<cols)
    out=np.full((rows,cols),np.inf,np.float32)
    np.minimum.at(out,(y[good],x[good]),r[good]);out[~np.isfinite(out)]=np.nan
    return out

def holes(points, mesh):
    depth=angular(points);measured=np.isfinite(depth)
    enclosed=ndimage.binary_fill_holes(measured)&~measured
    lab,n=ndimage.label(enclosed);sizes=np.bincount(lab.ravel())[1:]
    used=np.unique(mesh.triangles) if len(mesh.triangles) else np.array([],int)
    return dict(enclosed_missing_angular_cells=int(enclosed.sum()),enclosed_components=int(n),
                enclosed_components_gt4_cells=int((sizes>4).sum()),largest_enclosed_cells=int(sizes.max()) if n else 0,
                measured_vertices_without_triangle=int(mesh.observed.sum()-mesh.observed[used].sum()),
                metric_scope='Angular occupancy only; excludes open boundaries; not a surface area or material classifier')

def png(mesh,points,path,title):
    # Sensor viewpoint, no fabricated rear faces. Painter raster is a preview only.
    w,h=960,600;im=Image.new('RGB',(w,h),(230,238,243));d=ImageDraw.Draw(im)
    v=mesh.vertices; camera=np.array([-.1,0,.08]);rel=v-camera
    dep=rel[:,0];safe=np.maximum(dep,.01)
    uv=np.column_stack((w/2-520*rel[:,1]/safe,h*.58-520*rel[:,2]/safe))
    light=np.array([-.4,-.3,.85]);light/=np.linalg.norm(light)
    for k in np.argsort(-dep[mesh.triangles].mean(axis=1)):
        ids=mesh.triangles[k]
        if (dep[ids]<.15).any():continue
        q=uv[ids]
        if q[:,0].max()<0 or q[:,0].min()>w or q[:,1].max()<0 or q[:,1].min()>h:continue
        shade=.55+.45*abs(mesh.normals[ids].mean(axis=0)@light)
        color=np.array([155,171,182] if mesh.observed[ids].all() else [222,194,151])*shade
        d.polygon([tuple(a) for a in q],fill=tuple(color.astype(int)))
    d.rectangle((0,0,w,48),fill=(30,48,62));d.text((15,15),title,fill='white');im.save(path)
    p=points[::max(1,len(points)//80000)]/1000.;r=p-camera;keep=r[:,0]>.15;r=r[keep]
    uv=np.column_stack((w/2-520*r[:,1]/r[:,0],h*.58-520*r[:,2]/r[:,0]))
    raw=Image.new('RGB',(w,h),(230,238,243));d=ImageDraw.Draw(raw)
    for x,y in uv:
        if 0<=x<w and 48<=y<h:d.point((int(x),int(y)),fill=(53,104,133))
    d.rectangle((0,0,w,48),fill=(30,48,62));d.text((15,15),title+' / measured points',fill='white');raw.save(path.with_name(path.stem+'_points.png'))

def html(mesh,points,path,title):
    tree=ast.parse((ROOT/'web_server/render_surface_twin.py').read_text(encoding='utf-8'))
    page=next(ast.literal_eval(n.value) for n in tree.body if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='HTML' for t in n.targets))
    rgb=np.tile([.65,.72,.77],(len(mesh.vertices),1));rgb[~mesh.observed]=[.88,.75,.55]
    data=np.column_stack((mesh.vertices,mesh.normals,rgb)).astype('<f4')
    wire=np.concatenate([mesh.triangles[:,[0,1]],mesh.triangles[:,[1,2]],mesh.triangles[:,[2,0]]]).astype('<u4')
    def b(a):return base64.b64encode(a.tobytes()).decode('ascii')
    for k,val in dict(VERTICES=b(data),INDICES=b(mesh.triangles.astype('<u4')),WIREINDICES=b(wire),LINES='',BOX='[]',TRIANGLES=str(len(mesh.triangles)),SCANS='—',DISTANCE='—').items():page=page.replace('__'+k+'__',val)
    page=page.replace('静止场景表面近似重建',title).replace('橙色区域：左前方纸箱 · 最近水平距离 <b>— m</b>','灰蓝：实测表面；浅米：推算补面').replace('蓝灰色区域：地面、防护网及其他可见表面','走廊真实录制，有行人；未做动态物体剔除').replace('这是从雷达可见回波生成的平滑近似表面。防护网孔洞、遮挡背面和没有测到的物体细节无法还原；亮橙线框是算法输出的箱子可见范围。','未观测区域仍保留空洞。长窗口可能留下行人拖影；未验证雷达位姿，不是移动建图验收。')
    p=points[::max(1,len(points)//80000)].astype(np.float32)/1000;pr=np.column_stack((p,np.tile([0,0,1],(len(p),1)),np.tile([.2,.55,.75],(len(p),1)))).astype('<f4')
    page=page.replace('gl_Position=vec4(', 'gl_PointSize=2.0;gl_Position=vec4(')
    page=page.replace('const mesh=geometry(vertices,indices)',"const rawPoints=new Float32Array(bytes('"+b(pr)+"').buffer),rawVAO=geometry(rawPoints,null);let showPoints=false;const mesh=geometry(vertices,indices)")
    page=page.replace('gl.drawElements(gl.TRIANGLES,indices.length,gl.UNSIGNED_INT,0);','if(showPoints){gl.uniform1i(loc.u_line,1);gl.bindVertexArray(rawVAO);gl.drawArrays(gl.POINTS,0,rawPoints.length/9)}else gl.drawElements(gl.TRIANGLES,indices.length,gl.UNSIGNED_INT,0);')
    page=page.replace('<button id="wire">显示线框</button>','<button id="wire">显示线框</button> <button id="points">原始点/表面</button>')
    page=page.replace('window.addEventListener(\'resize\',schedule);render();',"document.getElementById('points').onclick=()=>{showPoints=!showPoints;schedule()};window.addEventListener('resize',schedule);render();")
    page=page.replace('radius=2.7','radius=6').replace('const target=[1,.2,.6]','const target=[2,0,.5]')
    path.write_text(page,encoding='utf-8')

def main():
    a=argparse.ArgumentParser();a.add_argument('--session',type=Path,default=ROOT/'sample/radar/corridor_dynamic_20261008_direct');a.add_argument('--out',type=Path,default=ROOT/'sample/car_showcase/corridor_dynamic_20261008');args=a.parse_args();args.out.mkdir(parents=True,exist_ok=True)
    stamps=[];chunks=[];bad=[];crc=missing=0;last=None
    for e in SessionReader(args.session):
        try:p=decode_mid360(e.payload,e.host_ns)
        except PacketError as ex:bad.append(str(ex));continue
        crc+=int(p.crc_present)
        if last is not None and p.udp_count!=(last+1)&65535:missing+=1
        last=p.udp_count;stamps.append(e.host_ns);chunks.append(np.column_stack([p.points[x] for x in ('x','y','z')]))
    if not stamps:raise RuntimeError('no valid packets')
    t=(np.asarray(stamps)-stamps[0])/1e9
    def window(center,duration):return np.concatenate([p for sec,p in zip(t,chunks) if abs(sec-center)<=duration/2])
    entries=[]
    for name,center,duration,fill in [('short_3s',3,.2,False),('short_7s',7,.2,False),('short_12s',12,.2,False),('fusion_2s',7,2,False),('fusion_2s_fill',7,2,True)]:
        cloud=window(center,duration);mesh=make_mesh(cloud,planar_fill=fill)
        assert np.isfinite(mesh.vertices).all() and (not len(mesh.triangles) or mesh.triangles.max()<len(mesh.vertices))
        write_binary(args.out/(name+'.m3mesh'),mesh)
        title=f'{name}: t={center}s, window={duration}s'
        html(mesh,cloud,args.out/(name+'.html'),title);png(mesh,cloud,args.out/(name+'.png'),title)
        stats=dict(name=name,center_s=center,window_s=duration,planar_fill=fill,**pack(mesh)['stats'],**holes(cloud,mesh));entries.append(stats)
        print(json.dumps(stats),flush=True)
    # Same angular rays changing in time: occlusion/motion/scan variation, not semantic labels.
    depths=np.stack([angular(window(6.1+i*.1,.1)) for i in range(20)])
    valid=np.isfinite(depths);minimum=np.min(np.where(valid,depths,np.inf),axis=0);maximum=np.max(np.where(valid,depths,-np.inf),axis=0)
    supported=valid.sum(axis=0)>=8;changing=supported&((maximum-minimum)>.3)
    report=dict(source=str(args.session),packets=len(stamps),bad_packets=len(bad),bad_examples=bad[:5],points=sum(len(x) for x in chunks),crc_present_packets=crc,sequence_discontinuities=missing,duration_s=float(t[-1]),windows=entries,
      temporal=dict(interval_s=[6.05,8.05],rays_observed_at_least_8_times=int(supported.sum()),rays_depth_span_gt300mm=int(changing.sum()),scope='motion/occlusion/range variation indicator, not person classification'),limitations=['No verified sensor pose; no motion compensation','Moving person is not removed','2s nearest-return fusion can preserve person trails','Hole metrics exclude open gaps and do not measure missing area'])
    (args.out/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    pages=''.join(f'<a target="view" href="{e["name"]}.html">{e["name"]}</a> ' for e in entries)
    (args.out/'index.html').write_text('<!doctype html><meta charset="utf-8"><title>走廊网格对照</title><style>body{margin:0;font:16px sans-serif;background:#e8edf0}nav{padding:12px}a{margin:8px}iframe{width:100%;height:calc(100vh - 56px);border:0}</style><nav>走廊真实数据 | '+pages+'</nav><iframe name="view" src="short_7s.html"></iframe>',encoding='utf-8')
    ims=[Image.open(args.out/(x+'.png')) for x in ('short_7s_points','short_7s','fusion_2s','fusion_2s_fill')]
    contact=Image.new('RGB',(1920,1200));
    for i,im in enumerate(ims):contact.paste(im,((i%2)*960,(i//2)*600))
    contact.save(args.out/'comparison.png')
    print('OUTPUT',args.out)
if __name__=='__main__':main()
