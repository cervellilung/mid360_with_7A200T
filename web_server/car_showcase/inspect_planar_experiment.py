"""Inspect saved real meshes: finite corner support, boundary gaps and topology."""
import argparse
import json
from pathlib import Path
import numpy as np
from scipy.spatial import cKDTree
from .build_planar_experiment import ROOT


def read_mesh(path):
    buffer=path.read_bytes(); header=np.frombuffer(buffer[:16],'<u4')
    magic,n,f,version=map(int,header)
    if magic!=0x4D335348 or version!=1 or len(buffer)!=16+n*37+f*12:raise ValueError('Invalid cache')
    vertices=np.frombuffer(buffer,dtype='<f4',count=n*3,offset=16).reshape(-1,3)
    faces=np.frombuffer(buffer,dtype='<u4',count=f*3,offset=16+24*n).reshape(-1,3)
    return vertices,faces


def topology(faces):
    edges=np.sort(np.concatenate([faces[:,(0,1)],faces[:,(1,2)],faces[:,(2,0)]]),axis=1)
    _,counts=np.unique(edges,axis=0,return_counts=True)
    unique=np.unique(np.sort(faces,axis=1),axis=0)
    return dict(boundary_edges=int((counts==1).sum()),nonmanifold_edges=int((counts>2).sum()),duplicate_faces=int(len(faces)-len(unique)))


def corners(points,vertices,faces,labels,planes):
    result=[]
    for a,left in enumerate(planes):
        for b in range(a+1,len(planes)):
            right=planes[b];n1,n2=np.asarray(left['normal']),np.asarray(right['normal'])
            dot=float(np.clip(n1@n2,-1,1));angle=float(np.degrees(np.arccos(abs(dot))))
            if angle<20:continue
            matrix=np.stack([n1,n2]);origin=np.linalg.lstsq(matrix,-np.array([left['offset_m'],right['offset_m']]),rcond=None)[0]
            direction=np.cross(n1,n2);direction/=np.linalg.norm(direction)
            supports=[];boundary=[]
            for group,plane in [(a,left),(b,right)]:
                n=np.asarray(plane['normal']);mask=np.abs(points@n+plane['offset_m'])<.020+.001*np.linalg.norm(points,axis=1)
                p=points[mask];s=(p-origin)@direction
                if not len(s):break
                supports.append((p,np.quantile(s,[.02,.98])))
                f=faces[labels==group]
                if not len(f):boundary.append(np.empty((0,3)));continue
                edges=np.sort(np.concatenate([f[:,(0,1)],f[:,(1,2)],f[:,(2,0)]]),axis=1)
                e,count=np.unique(edges,axis=0,return_counts=True)
                boundary.append(vertices[np.unique(e[count==1])])
            if len(supports)!=2:continue
            lo=max(supports[0][1][0],supports[1][1][0]);hi=min(supports[0][1][1],supports[1][1][1])
            if hi<=lo:continue
            locations=origin+np.arange(lo,hi,.05)[:,None]*direction
            d1=cKDTree(supports[0][0]).query(locations)[0];d2=cKDTree(supports[1][0]).query(locations)[0]
            valid=(d1<.20)&(d2<.20)
            gap=[]
            if valid.any() and all(len(x) for x in boundary):
                gap=cKDTree(boundary[0]).query(locations[valid])[0]+cKDTree(boundary[1]).query(locations[valid])[0]
            result.append(dict(groups=[a,b],unoriented_plane_angle_deg=angle,
                supported_intersection_samples=int(valid.sum()),sample_step_m=.05,
                boundary_gap_upper_p95_mm=float(np.percentile(gap,95)*1000) if len(gap) else None,
                joined=False,interpretation='Two-side returns within 0.20m; gap is distance-to-boundaries upper estimate, not a ground-truth crack width'))
    return result


def main():
    ap=argparse.ArgumentParser();ap.add_argument('--out',type=Path,default=ROOT/'sample/car_showcase/planar_corridor_20261009');args=ap.parse_args()
    report=json.loads((args.out/'manifest.json').read_text(encoding='utf-8'));results=[]
    for entry in report['frames']:
        if entry['t'] not in (3,7,11):continue
        p=np.fromfile(args.out/entry['points'],dtype='<f4').reshape(-1,4)[:,:3]
        spec=entry['variants']['planar'];v,f=read_mesh(args.out/spec['mesh']);labels=np.fromfile(args.out/spec['groups'],dtype='<i2')
        checks={name:topology(read_mesh(args.out/value['mesh'])[1]) for name,value in entry['variants'].items()}
        results.append(dict(t=entry['t'],topology=checks,corners=corners(p,v,f,labels,spec['stats']['diagnostics']['planes'])))
    (args.out/'inspection.json').write_text(json.dumps(results,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps([{'t':r['t'],'topology':r['topology'],'corner_pairs':len(r['corners'])} for r in results]))


if __name__=='__main__':main()
