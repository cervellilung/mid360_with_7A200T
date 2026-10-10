"""Compare stored metre/angle planar candidates using identical real inputs."""
import argparse
import json
from pathlib import Path
from types import SimpleNamespace
import numpy as np
from .build_planar_experiment import compare_coverage
from .surface_distance import surface_distances


def read_mesh(folder, name):
    data = (folder/name).read_bytes()
    header = np.frombuffer(data, '<u4', count=4)
    magic, nv, nf, version = map(int, header)
    if magic != 0x4D335348 or version != 1 or len(data) != 16+37*nv+12*nf:
        raise ValueError('Invalid mesh cache')
    vertices = np.frombuffer(data, '<f4', count=nv*3, offset=16).reshape(-1,3)
    triangles = np.frombuffer(data, '<u4', count=nf*3, offset=16+nv*24).reshape(-1,3)
    if not np.isfinite(vertices).all() or (len(triangles) and triangles.max() >= nv):
        raise ValueError('Invalid geometry')
    return SimpleNamespace(vertices=vertices, triangles=triangles)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--before', type=Path, default=Path('sample/car_showcase/planar_top_recovery_6m'))
    parser.add_argument('--after', type=Path, default=Path('sample/car_showcase/planar_angular_support_6m'))
    parser.add_argument('--out', type=Path, default=Path('results/planar_angular_support/comparison.json'))
    args = parser.parse_args()
    old = json.loads((args.before/'manifest.json').read_text(encoding='utf-8'))
    new = json.loads((args.after/'manifest.json').read_text(encoding='utf-8'))
    assert old['source_sha256'] == new['source_sha256'] and old['window_ms'] == new['window_ms'] == 200
    assert old['config']['max_range'] == new['config']['max_range'] == 6
    assert len(old['frames']) == len(new['frames'])
    frames = []
    for a, b in zip(old['frames'], new['frames']):
        assert a['t'] == b['t'] and a['input_sha256'] == b['input_sha256']
        assert a['filtered_input_sha256'] == b['filtered_input_sha256']
        for name in ('angular','baseline'):
            for field in ('mesh','groups','inferred'):
                assert (args.before/a['variants'][name][field]).read_bytes() == (args.after/b['variants'][name][field]).read_bytes()
        av, bv = a['variants']['planar'], b['variants']['planar']
        before, after = read_mesh(args.before,av['mesh']), read_mesh(args.after,bv['mesh'])
        assert np.array_equal(before.vertices,after.vertices)
        assert set(map(tuple,before.triangles)).issubset(set(map(tuple,after.triangles)))
        assert np.linalg.norm(after.vertices.astype(float),axis=1).max() <= 6+1e-6
        groups = np.fromfile(args.after/bv['groups'],'<i2')
        flags = np.fromfile(args.after/bv['inferred'],'u1')
        assert len(groups) == len(flags) == len(after.triangles)
        d = bv['stats']['diagnostics']
        planes = []
        for p in d['planes']:
            indices = np.unique(after.triangles[groups==p['group']])
            planes.append(dict(normal=np.array(p['normal']),offset=p['offset_m'],
                centre=after.vertices[indices].mean(axis=0)))
        angle = read_mesh(args.after,b['variants']['angular']['mesh'])
        coverage_before, coverage_after = compare_coverage(angle,before,planes),compare_coverage(angle,after,planes)
        assert coverage_after['duplicate_faces'] == coverage_before['duplicate_faces']
        assert coverage_after['nonmanifold_edges'] <= coverage_before['nonmanifold_edges']
        probes = []
        for p in planes:
            if abs(p['normal'][2])>.95 and p['centre'][2]>0:
                z = -p['offset']/p['normal'][2]
                probes.append([0,0,z])
        centre_distance = surface_distances(np.array(probes),after).tolist() if probes else []
        assert all(x>.5 for x in centre_distance), 'Unobserved overhead centre was filled'
        row = dict(t=b['t'],old_faces=len(before.triangles),new_faces=len(after.triangles),
            angular_added=sum(p['angular_recovered'] for p in d['planes']),
            ceiling_added=sum(p['angular_recovered'] for p in d['planes'] if abs(p['normal'][2])>.95 and p['offset_m']>0),
            old_holdout=a['holdout']['planar'],new_holdout=b['holdout']['planar'],
            complete_ms=b['reconstruction_pair_ms'],coverage_before=coverage_before,
            coverage_after=coverage_after,overhead_unknown_centre_distance_m=centre_distance,
            input_sha256=b['input_sha256'])
        frames.append(row)
        print(f"t={b['t']:g}s added={row['angular_added']} ceiling_added={row['ceiling_added']} old/new_holdout_p95={row['old_holdout']['p95_mm']:.2f}/{row['new_holdout']['p95_mm']:.2f}mm complete={row['complete_ms']:.0f}ms",flush=True)
    args.out.parent.mkdir(parents=True,exist_ok=True)
    args.out.write_text(json.dumps(dict(frames=frames,
        checks='Identical input/range/window; references byte-identical; old planar faces retained; finite ROI; no new duplicate/nonmanifold edges; unobserved overhead stays open',
        limitations='Coverage relative to a baseline surface is not physical opening truth. No labelled doors or occlusions in the recording.'),indent=2),encoding='utf-8')


if __name__ == '__main__': main()
