"""Independent finite-surface holdout and topology checks on real windows."""
import json
from pathlib import Path
import numpy as np
from .build_planar_experiment import ROOT,read_windows
from .adaptive_mesh import make_angular_mesh
from .fast_mesh import make_fast_mesh
from .surface_distance import surface_distances,summary
from .inspect_planar_experiment import topology


def main():
    windows,source=read_windows(ROOT/'sample/radar/corridor_dynamic_20261008_direct',[3,7,11])
    rows=[]
    for w in windows:
        cloud=w['cloud'];r=np.linalg.norm(cloud.astype(np.float32)/1000,axis=1)
        cloud=cloud[(r>=.3)&(r<=12)]
        order=np.random.default_rng(20261009).permutation(len(cloud));split=len(cloud)//5
        train=cloud[order[split:]];test=cloud[order[:min(split,1024)]].astype(np.float64)/1000
        result=dict(t=w['t'],input_sha256=w['input_sha256'],train_points=len(train),held_out_pool=split,evaluated_holdout=len(test))
        for name,fn in [('angular',make_angular_mesh),('fast',make_fast_mesh)]:
            mesh=fn(train);dist=surface_distances(test,mesh)
            result[name]=dict(residual=summary(dist),topology=topology(mesh.triangles),faces=len(mesh.triangles),
                reconstruction_ms=mesh.build_ms,display_shift_p95_mm=mesh.p95_shift_mm,diagnostics=mesh.diagnostics)
        rows.append(result)
        print(w['t'],{k:result[k]['residual'] for k in ['angular','fast']},flush=True)
    target=ROOT/'results/fast_mesh_20261009/evaluation.json'
    target.write_text(json.dumps(dict(source=source,rows=rows,seed=20261009,
        scope='20% completely excluded from fitting/meshing/repair gates; deterministic 1024-point subset evaluated against finite triangles. Runtime evaluation excluded from reconstruction timing. No semantic door ground truth.'),indent=2),encoding='utf-8')
    print('OUTPUT',target)


if __name__=='__main__':main()
