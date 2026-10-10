"""Bounded-window PC display candidate. No whole-plane hull or history fusion.

Reuses angular topology and feature-aware projection; speeds up local geometry
instead of substituting a cached map. Raw measurements remain authoritative.
"""
from dataclasses import dataclass, asdict
import time
import numpy as np
from scipy.spatial import cKDTree
from .adaptive_mesh import AngularConfig, make_angular_mesh
from .feature_mesh import FeatureConfig, make_feature_mesh, EDGE


@dataclass(frozen=True)
class FastConfig:
    angular: AngularConfig = AngularConfig(step_deg=.8,normal_neighbours=12,
        normal_iterations=2,normal_float32=True,spacing_factor=3.,max_angle_deg=4.,candidate_mode='sphere')
    feature: FeatureConfig = FeatureConfig(min_support=8,strength=.55,max_shift_m=.006,shift_range_factor=.0005)


def make_fast_mesh(points_mm, config=None):
    cfg=config or FastConfig();started=time.perf_counter()
    base=make_angular_mesh(points_mm,cfg.angular,include_geometry=True,include_audit=True,defer_normals=True)
    _restore_supported_faces(base,points_mm)
    mesh=make_feature_mesh(points_mm,cfg.feature,base=base)
    if hasattr(base,'voted_geometry'):
        labels,normals=base.voted_geometry
        flat=(labels>=0)&(mesh.features!=EDGE)
        fitted=normals[labels[flat]].copy()
        fitted[np.einsum('ni,ni->n',fitted,-mesh.raw_vertices[flat])<0]*=-1
        mesh.normals[flat]=fitted
    mesh.build_ms=(time.perf_counter()-started)*1000
    mesh.diagnostics.update(algorithm='fast_local_surface_v4',fast_config=asdict(cfg),
        scope='Single current 200ms window; plane votes only repair finite supported angular candidates, no hull/map/backfaces/cached topology',
        topology='angular candidates plus observation-supported same-plane recovery',
        budget_ms=300,budget_exceeded=mesh.build_ms>300)
    return mesh


def _restore_supported_faces(base,points_mm):
    """Fast plane voting only repairs existing angular candidates, never a hull.

    Local normals vote in coarse orientation/offset bins. Large bins seed a
    least-squares fit; all vertices are checked against that finite observation
    set. Candidate interior rays must have nearby actual returns consistent
    with the plane, including foreground/background conflict rejection.
    """
    if not hasattr(base,'local_geometry'):return
    g=base.local_geometry;v=base.raw_vertices;n=g['normal'].copy()
    flip=n[np.arange(len(n)),np.argmax(np.abs(n),axis=1)]<0;n[flip]*=-1
    offset=np.einsum('ni,ni->n',n,v)
    keys=np.column_stack((np.rint(n/.15),np.rint(offset/.20))).astype(np.int32)
    reliable=np.flatnonzero(g['reliable'])
    if len(reliable)<300:return
    _,inv,counts=np.unique(keys[reliable],axis=0,return_inverse=True,return_counts=True)
    groups=np.argsort(counts)[::-1]
    plane_ids=np.full(len(v),-1,np.int16);planes=[]
    for group in groups:
        if counts[group]<120 or len(planes)>=6:break
        ids=reliable[inv==group];p=v[ids];centre=p.mean(axis=0)
        _,vectors=np.linalg.eigh((p-centre).T@(p-centre));normal=vectors[:,0]
        d=float(normal@centre)
        if any(abs(normal@pn)>.995 and abs(d*(1 if normal@pn>0 else -1)-pd)<.04 for pn,pd in planes):continue
        residual=np.abs(np.einsum('ni,i->n',v,normal)-d)
        agree=np.abs(np.einsum('ni,i->n',n,normal))>np.cos(np.radians(25))
        mask=(residual<.020+.001*g['radius']) & agree & (plane_ids<0)
        if mask.sum()<300:continue
        # Refit from the observation-supported group, not any invented samples.
        p=v[mask];centre=p.mean(axis=0);_,vec=np.linalg.eigh((p-centre).T@(p-centre));normal=vec[:,0];d=float(normal@centre)
        mask &= np.abs(np.einsum('ni,i->n',v,normal)-d)<.020+.001*g['radius']
        plane_ids[mask]=len(planes);planes.append((normal,d))
    if planes:base.voted_geometry=(plane_ids,np.array([p[0] for p in planes],np.float32))
    audit=base.audit;candidates=audit['candidates'];reasons=audit['reasons']
    labels=plane_ids[candidates]
    # A depth/normal rejection may be revisited; angle/degeneracy rejection may not.
    eligible=(reasons!=0)&((reasons&17)==0)&(labels[:,0]>=0)&np.all(labels==labels[:,:1],axis=1)
    ids=np.flatnonzero(eligible)
    if not len(ids):
        base.diagnostics.update(recovered_faces=0,voted_planes=len(planes));return
    pts=np.asarray(points_mm,np.float32).reshape(-1,3)/1000;r=np.linalg.norm(pts,axis=1)
    ok=np.isfinite(pts).all(axis=1)&(r>=.3)&(r<=12);pts=pts[ok];r=r[ok]
    rays=pts/r[:,None];tree=cKDTree(rays)
    tri=v[candidates[ids]]
    probes=np.stack((tri.mean(axis=1),(tri[:,0]+tri[:,1])/2,(tri[:,0]+tri[:,2])/2,(tri[:,1]+tri[:,2])/2),axis=1)
    directions=probes/np.linalg.norm(probes,axis=2,keepdims=True)
    chord,near=tree.query(directions.reshape(-1,3),k=4,workers=1)
    pn=np.array([planes[i][0] for i in labels[ids,0]]);pd=np.array([planes[i][1] for i in labels[ids,0]])
    # Test each actual nearby ray, not the interpolated probe's range.
    den=np.einsum('npki,ni->npk',rays[near].reshape(-1,4,4,3),pn)
    expected=pd[:,None,None]/np.where(np.abs(den)>.05,den,np.nan)
    actual=r[near].reshape(-1,4,4)
    nearby=chord.reshape(-1,4,4)<2*np.sin(np.radians(1.6)/2)
    consistent=nearby & (np.abs(actual-expected)<.035+.003*actual)
    conflict=nearby & (np.abs(actual-expected)>.08+.005*actual)
    supported=consistent.any(axis=2).all(axis=1)&(conflict.sum(axis=2)<2).all(axis=1)
    restored=candidates[ids[supported]]
    base.triangles=np.concatenate((base.triangles,restored)).astype(np.uint32)
    base.diagnostics.update(recovered_faces=len(restored),recovery_candidates=len(ids),voted_planes=len(planes))
