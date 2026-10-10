"""Benchmark real 200ms windows in memory; report cold and repeated maximum."""
import argparse,json,time
from pathlib import Path
import numpy as np
from .build_planar_experiment import read_windows, ROOT
from .adaptive_mesh import make_angular_mesh
from .fast_mesh import make_fast_mesh


def main():
    ap=argparse.ArgumentParser();ap.add_argument('--times',default='3,7,11');ap.add_argument('--repeat',type=int,default=3)
    ap.add_argument('--out',type=Path,default=ROOT/'results/fast_mesh_20261009/benchmark.json');args=ap.parse_args()
    windows,source=read_windows(ROOT/'sample/radar/corridor_dynamic_20261008_direct',[float(x) for x in args.times.split(',')])
    rows=[]
    for w in windows:
        for name,fun in [('angular',make_angular_mesh),('fast',make_fast_mesh)]:
            durations=[]
            for i in range(args.repeat):
                started=time.perf_counter();mesh=fun(w['cloud']);duration=(time.perf_counter()-started)*1000;durations.append(duration)
            row=dict(t=w['t'],algorithm=name,ms=durations,faces=len(mesh.triangles),vertices=len(mesh.vertices),p95_shift_mm=mesh.p95_shift_mm)
            rows.append(row);print(f't={w["t"]} {name}: ms={np.round(durations,1).tolist()} faces={len(mesh.triangles)} shiftP95={mesh.p95_shift_mm:.2f}mm',flush=True)
    all_fast=np.concatenate([r['ms'] for r in rows if r['algorithm']=='fast'])
    result=dict(rows=rows,source=source,scope='Includes all reconstruction; excludes recording read, screenshot, disk serialization and window acquisition',
                fast_median_ms=float(np.median(all_fast)),fast_p95_ms=float(np.percentile(all_fast,95)),fast_max_ms=float(all_fast.max()),budget_ms=300,passed=bool((all_fast<=300).all()))
    args.out.parent.mkdir(parents=True,exist_ok=True);args.out.write_text(json.dumps(result,indent=2),encoding='utf-8')
    print('MAX_MS',result['fast_max_ms'],'PASS',result['passed'])
    return 0 if result['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
