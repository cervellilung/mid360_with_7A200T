"""Fixed 200 ms real-recording comparisons; no hardware, accumulation or SLAM."""
import argparse
from dataclasses import asdict
import hashlib
import json
from pathlib import Path
import time
import numpy as np
from PIL import Image, ImageDraw
from scipy.spatial import cKDTree
from web_server.pc_perception.session import SessionReader
from web_server.pc_perception.protocol import decode_mid360, PacketError
from .planar_mesh import PlanarConfig, make_planar_mesh, make_range_baseline, valid_points, ring_supported, ray_contradictions
from .surface_distance import surface_distances, summary
from .assets import write_binary
from .mesh import make_mesh
from .hybrid_mesh import make_hybrid_mesh

ROOT = Path(__file__).resolve().parents[2]


def read_windows(recording, ends):
    chunks = [[] for _ in ends]; packets = [0]*len(ends); stamps = [[] for _ in ends]
    first = None; bad = crc = total = gaps = 0; last = None
    for event in SessionReader(recording):
        if first is None: first = event.host_ns
        try: packet = decode_mid360(event.payload,event.host_ns)
        except PacketError: bad += 1; continue
        total += 1; crc += int(packet.crc_present)
        if last is not None and packet.udp_count != ((last+1)&65535): gaps += 1
        last = packet.udp_count
        t = (event.host_ns-first)/1e9
        for i, end in enumerate(ends):
            if end-.2 < t <= end:
                chunks[i].append(np.column_stack([packet.points[k] for k in ('x','y','z')]))
                packets[i] += 1; stamps[i].append(event.host_ns)
    windows = []
    for end, data, count, ns in zip(ends,chunks,packets,stamps):
        if not data: raise ValueError(f'No real packets in ({end-.2},{end}] seconds')
        cloud = np.concatenate(data).astype('<i4')
        windows.append(dict(t=end, cloud=cloud, packets=count,
            input_sha256=hashlib.sha256(cloud.tobytes()).hexdigest(),
            stamps_sha256=hashlib.sha256(np.asarray(ns,dtype='<i8').tobytes()).hexdigest()))
    return windows, dict(packets=total, bad_packets=bad, crc_present=crc, counter_discontinuities=gaps)


def supported_gap_area(points, planes, meshes):
    """Raster estimate ONLY in a training-supported planar domain, same for both.

    Not ground truth, and not a test for a semantic door. Open edges excluded.
    """
    reports = []
    radii=np.linalg.norm(points,axis=1); rays=points/radii[:,None]; ray_tree=cKDTree(rays)
    for group, plane in enumerate(planes):
        uv = (points[plane['ids']]-plane['centre'])@plane['basis'].T
        tree = cKDTree(uv)
        if len(uv) < 10: continue
        spacing = tree.query(uv,k=7)[0][:,-1]
        step = float(np.clip(np.median(spacing),.03,.12))
        lo, hi = uv.min(axis=0), uv.max(axis=0)
        size = np.ceil((hi-lo)/step).astype(int)+1
        if np.prod(size) > 120000:
            step *= np.sqrt(np.prod(size)/120000); size = np.ceil((hi-lo)/step).astype(int)+1
        xx, yy = np.meshgrid(np.arange(size[0]),np.arange(size[1]))
        probes = lo+(np.c_[xx.ravel(),yy.ravel()]+.5)*step
        distance, nearest = tree.query(probes)
        local = np.maximum(.02,np.minimum(spacing[nearest],np.linalg.norm(points[plane['ids']][nearest],axis=1)*np.radians(3.2)))
        domain = distance <= .65*local
        candidates = np.flatnonzero(~domain & (distance <= 1.15*local) & (distance <= .20))
        domain[candidates] = ring_supported(probes[candidates],tree,uv,local[candidates])
        xyz=probes@plane['basis']+plane['centre']; xyz-=(xyz@plane['normal']+plane['offset'])[:,None]*plane['normal']
        domain &= ~ray_contradictions(xyz,plane['normal'],plane['offset'],ray_tree,rays,radii)
        domain = domain.reshape(size[1],size[0])
        masks = []
        for mesh in meshes:
            tri = mesh.vertices[mesh.triangles]
            near = (np.abs(tri@plane['normal']+plane['offset']) <= .04).all(axis=1)
            tri_uv = (tri[near]-plane['centre'])@plane['basis'].T
            image = Image.new('1',(int(size[0]),int(size[1]))); draw = ImageDraw.Draw(image)
            for triangle in (tri_uv-lo)/step-.5:
                draw.polygon([tuple(x) for x in triangle],fill=1)
            masks.append(np.asarray(image,bool))
        gaps = [float((domain & ~mask).sum()*step*step) for mask in masks]
        reports.append(dict(group=group,cell_m=step,supported_domain_m2=float(domain.sum()*step*step),
                            angular_gap_m2=gaps[0], planar_gap_m2=gaps[1]))
    return reports


def save_variant(out, name, mesh):
    write_binary(out/(name+'.m3mesh'),mesh)
    group = getattr(mesh,'face_group',np.full(len(mesh.triangles),-1,np.int16))
    inferred = getattr(mesh,'face_inferred',(~mesh.observed[mesh.triangles]).any(axis=1).astype(np.uint8))
    # Per-face data; neither inferred nor plane labels are measurement flags.
    group.astype('<i2').tofile(out/(name+'.groups'))
    inferred.astype('u1').tofile(out/(name+'.inferred'))
    extras = {}
    for attribute, suffix, dtype in [('face_normals','face_normals','<f4'),('face_region','regions','u1')]:
        if hasattr(mesh, attribute):
            getattr(mesh,attribute).astype(dtype).tofile(out/(name+'.'+suffix))
            extras[suffix] = name+'.'+suffix
    return dict(mesh=name+'.m3mesh', groups=name+'.groups',inferred=name+'.inferred',**extras,
        stats=dict(vertices=len(mesh.vertices),triangles=len(mesh.triangles),build_ms=mesh.build_ms,
                   p95_shift_mm=mesh.p95_shift_mm,diagnostics=getattr(mesh,'hybrid_report',getattr(mesh,'planar_report',getattr(mesh,'diagnostics',{})))))


def compare_coverage(base, candidate, planes):
    """Samples of the BASELINE surface, not ground-truth physical hole area."""
    triangle = base.vertices[base.triangles].astype(float)
    area = np.linalg.norm(np.cross(triangle[:,1]-triangle[:,0],triangle[:,2]-triangle[:,0]),axis=1)/2
    reports = []
    for group, plane in enumerate(planes):
        normal, offset = plane['normal'],plane['offset']
        same = (np.abs(triangle@normal+offset)<=.020+.001*np.linalg.norm(triangle,axis=2)).all(axis=1)
        ids = np.flatnonzero(same)
        if not len(ids):continue
        ii = np.random.default_rng(44).choice(ids,min(1500,len(ids)),replace=False)
        tri = triangle[ii]
        probes = np.concatenate([tri.mean(axis=1),(tri[:,0]+tri[:,1])/2,(tri[:,0]+tri[:,2])/2,(tri[:,1]+tri[:,2])/2])
        distance = surface_distances(probes,candidate).reshape(4,-1)
        lost = (distance>.05).any(axis=0)
        reports.append(dict(group=group,normal=normal.tolist(),offset_m=float(offset),
            baseline_faces=len(ids),samples=len(ii),max_probe_mm=float(distance.max()*1000),
            lost_faces=int(lost.sum()),lost_area_fraction=float(area[ii][lost].sum()/max(area[ii].sum(),1e-12)),
            region='upper_horizontal' if abs(normal[2])>.95 and plane['centre'][2]>0 else 'other'))
    edges=np.sort(np.concatenate([candidate.triangles[:,[0,1]],candidate.triangles[:,[1,2]],candidate.triangles[:,[2,0]]]),axis=1)
    _,counts=np.unique(edges,axis=0,return_counts=True)
    canonical=np.sort(candidate.triangles,axis=1)
    return dict(planes=reports,nonmanifold_edges=int((counts>2).sum()),
        duplicate_faces=len(canonical)-len(np.unique(canonical,axis=0)),
        policy='1500 fixed-seed baseline faces per plane, centroid plus three edge probes; 50mm coverage threshold, not physical ground truth')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--recording',type=Path,default=ROOT/'sample/radar/corridor_dynamic_20261008_direct')
    parser.add_argument('--out',type=Path,default=ROOT/'sample/car_showcase/planar_corridor_6m')
    parser.add_argument('--times',default='3,7,11')
    parser.add_argument('--plane-mm',type=float,default=20)
    parser.add_argument('--connection-scale',type=float,default=2.8)
    parser.add_argument('--hole-radius',type=float,default=.20)
    parser.add_argument('--max-angle',type=float,default=3.2)
    parser.add_argument('--max-range',type=float,default=6.)
    parser.add_argument('--skip-holdout',action='store_true')
    parser.add_argument('--hybrid',action='store_true',help='Add bounded angular/planar fusion; keep all three references')
    parser.add_argument('--support-angle',type=float,default=2.4,help='Angular enclosing-support radius, degrees')
    parser.add_argument('--no-angular-support',action='store_true',help='Reproduce previous metre-bounded planar recovery')
    args = parser.parse_args()
    ends = sorted(set(float(x) for x in args.times.split(',')))
    if not ends or not all(.2 <= x <= 15 for x in ends): parser.error('times must be in [.2,15]')
    if not (5<=args.plane_mm<=40 and 1.5<=args.connection_scale<=4 and .02<=args.hole_radius<=.4 and .8<=args.max_angle<=3.2): parser.error('Parameters outside bounded experimental range')
    if not np.isfinite(args.max_range) or not .3<args.max_range<=6:
        parser.error('max-range must be greater than .3 and at most 6 m')
    if not np.isfinite(args.support_angle) or not .1<=args.support_angle<=3.2:
        parser.error('support-angle must be in [.1,3.2] degrees')
    cfg = PlanarConfig(plane_m=args.plane_mm/1000,connection_scale=args.connection_scale,hole_radius_m=args.hole_radius,max_angle_deg=args.max_angle,max_range=args.max_range,
        angular_gap_support=not args.no_angular_support,support_angle_deg=args.support_angle)
    args.out.mkdir(parents=True,exist_ok=True)
    windows, provenance = read_windows(args.recording,ends)
    entries = []; started = time.perf_counter()
    for window in windows:
        cloud = window.pop('cloud'); p, ids = valid_points(cloud,cfg)
        if not len(p): raise ValueError(f'No measured points within {cfg.max_range:g} m at t={window["t"]}')
        reconstruct_started = time.perf_counter()
        base = make_range_baseline(cloud,cfg)
        candidate = make_planar_mesh(cloud,cfg,base=base)
        reconstruction_ms = (time.perf_counter()-reconstruct_started)*1000
        legacy = make_mesh(cloud[ids], min_range=cfg.min_range, max_range=cfg.max_range)
        variants = [('angular',base),('baseline',legacy),('planar',candidate)]
        hybrid = make_hybrid_mesh(cloud,cfg) if args.hybrid else None
        if hybrid is not None: variants.append(('hybrid',hybrid))
        filtered_sha256 = hashlib.sha256(cloud[ids].tobytes()).hexdigest()
        stem = f't{window["t"]:05.2f}'
        pair = {name:save_variant(args.out,stem+'_'+name,mesh) for name,mesh in variants}
        # Every range-valid measured point, including those omitted by angular bins.
        status = np.zeros(len(cloud),np.uint8)
        status[base.audit['selected_source_ids']] = 2
        status[base.audit['selected_source_ids'][np.unique(base.triangles)]] = 1
        np.c_[p,status[ids]].astype('<f4').tofile(args.out/(stem+'.points'))
        rejected = base.audit['reasons'] != 0
        np.c_[base.vertices[base.audit['candidates'][rejected]].mean(axis=1),base.audit['reasons'][rejected]].astype('<f4').tofile(args.out/(stem+'.rejected'))
        np.savez_compressed(args.out/(stem+'.audit.npz'),vertices=base.vertices,**base.audit)
        audit = dict(range_valid=len(p),selected_vertices=len(base.vertices),bucket_removed=base.audit['bucket_removed'],
            elevation_removed=base.audit['elevation_removed'],selected_unused=int((status[ids]==2).sum()),
            reason_bits={name:int(((base.audit['reasons'] & bit)!=0).sum()) for name,bit in [('angle',1),('tangent',2),('normal',4),('radial_fallback',8),('degenerate',16)]})
        rng = np.random.default_rng(771)
        sample = p[rng.choice(len(p),min(2048,len(p)),replace=False)]
        residual = {name:summary(surface_distances(sample,mesh)) for name,mesh in variants}
        holdout = None
        if not args.skip_holdout:
            permutation = np.random.default_rng(20261009).permutation(len(p)); n = len(p)//5
            test, train = p[permutation[:n]],p[permutation[n:]]
            training_mm = np.rint(train*1000).astype(np.int32)
            train_base = make_range_baseline(training_mm,cfg)
            train_candidate = make_planar_mesh(training_mm,cfg,base=train_base)
            train_legacy = make_mesh(training_mm,min_range=cfg.min_range,max_range=cfg.max_range)
            holdout = dict(seed=20261009,train_points=len(train),test_points=len(test),
                training_sha256=hashlib.sha256(training_mm.tobytes()).hexdigest(),
                policy='Withheld points never enter fitting, Delaunay, support or ray gates',
                angular=summary(surface_distances(test,train_base)),baseline=summary(surface_distances(test,train_legacy)),planar=summary(surface_distances(test,train_candidate)))
            if args.hybrid:
                train_hybrid=make_hybrid_mesh(training_mm,cfg)
                holdout['hybrid']=summary(surface_distances(test,train_hybrid))
        gap = supported_gap_area(p,candidate.planes,[base,candidate])
        entry = dict(**window,window_ms=200,points=stem+'.points',rejected=stem+'.rejected',audit_file=stem+'.audit.npz',
            variants=pair,audit=audit,residual=residual,holdout=holdout,supported_gap_area=gap,
            filtered_input_sha256=filtered_sha256,max_range=cfg.max_range,
            reconstruction_pair_ms=reconstruction_ms,range_removed=len(cloud)-len(p))
        if hybrid is not None:
            entry['hybrid_coverage']=compare_coverage(base,hybrid,hybrid.planes)
            entry['hybrid_reconstruction_ms']=hybrid.build_ms
            print(f'hybrid t={window["t"]:g}s faces={len(hybrid.triangles)} complete_ms={hybrid.build_ms:.0f} retained={hybrid.hybrid_report["retained_source_faces"]} corners={hybrid.hybrid_report["corners"]["split_source_faces"]}',flush=True)
        entries.append(entry)
        print(f't={window["t"]:g}s points={len(p)} faces_angular_legacy_planar={len(base.triangles)}/{len(legacy.triangles)}/{len(candidate.triangles)} build_ms={base.build_ms:.0f}/{legacy.build_ms:.0f}/{candidate.build_ms:.0f} planar_total_ms={reconstruction_ms:.0f}',flush=True)
    report = dict(algorithm='planar_support_experiment_v2',config=asdict(cfg),source=str(args.recording),
        source_sha256=hashlib.sha256((args.recording/'events.bin').read_bytes()).hexdigest(),
        provenance=provenance,window_ms=200,frames=entries,build_s=time.perf_counter()-started,
        variants=['angular','baseline','planar']+(['hybrid'] if args.hybrid else []),
        presentation=dict(default_variant='hybrid' if args.hybrid else 'planar',default_comparison=True,max_range=cfg.max_range,
            label=f'仅重建{cfg.max_range:g} m内观测表面'),
        evaluation='Finite triangle distance; full-input residual sample 2048, disjoint 20% holdout',
        limitations=['No accumulated map, pose, SLAM or dynamic segmentation',
          'Raster supported-domain holes are estimates, not physical scene completeness',
          'No confirmed semantic door labels; unknown opening candidates only',
          'Folds independently meshed; no unsupported corner zipper',
          'Source protocol CRC fields zero: structure checked, source CRC not verified',
          'Per-face inferred colour is a geometric support classification, not ground truth'])
    (args.out/'manifest.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    print(f'OUTPUT:{args.out} SECONDS:{report["build_s"]:.1f}',flush=True)


if __name__=='__main__': main()
