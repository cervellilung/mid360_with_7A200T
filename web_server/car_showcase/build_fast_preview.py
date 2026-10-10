"""Build fair original/fast PC previews from real, fixed 200ms windows."""
import argparse
from dataclasses import asdict
import json
from pathlib import Path
import numpy as np
from .build_planar_experiment import ROOT,read_windows
from .adaptive_mesh import make_angular_mesh
from .fast_mesh import make_fast_mesh,FastConfig
from .assets import write_binary
from .build_angular_preview import metrics


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,default=ROOT/'sample/car_showcase/fast_corridor_20261009')
    args=parser.parse_args();args.out.mkdir(parents=True,exist_ok=True)
    (args.out/'frames').mkdir(exist_ok=True)
    windows,source=read_windows(ROOT/'sample/radar/corridor_dynamic_20261008_direct',np.arange(2,12.01,.5))
    frames=[]
    for i,w in enumerate(windows):
        cloud=w['cloud'];radius=np.linalg.norm(cloud.astype(np.float32)/1000,axis=1)
        raw=cloud[(radius>=.3)&(radius<=12)].astype('<f4')/1000
        rawfile=f'frames/raw_{i:03d}.f32';raw.astype('<f4').tofile(args.out/rawfile)
        entry=dict(t=w['t'],input_sha256=w['input_sha256'],raw_points=len(raw),variants={})
        for name,fun in [('angular',make_angular_mesh),('feature',make_fast_mesh)]:
            mesh=fun(cloud);filename=f'frames/{name}_{i:03d}.m3mesh'
            write_binary(args.out/filename,mesh)
            spec=dict(mesh=filename,stats=metrics(mesh),raw_points=rawfile)
            if hasattr(mesh,'features'):
                spec['features']=f'frames/{name}_{i:03d}.features'
                mesh.features.tofile(args.out/spec['features'])
            entry['variants'][name]=spec
        frames.append(entry)
        print(f't={w["t"]:.1f} angular={entry["variants"]["angular"]["stats"]["build_ms"]:.1f}ms fast={entry["variants"]["feature"]["stats"]["build_ms"]:.1f}ms',flush=True)
    report=dict(source=source,variants=['angular','feature'],algorithm='fast_local_surface_v4',config=asdict(FastConfig()),
        frames=frames,sample_hz=2,comparisons={'200':next(f['variants'] for f in frames if f['t']==7)},
        presentation=dict(title='真实走廊 · 原角度算法 / 快速保边表面',
            descriptions=dict(angular=['原角度自适应','0.8°分桶 · 原参数'],feature=['快速保边表面','球面邻接 · 无分区接缝 · 局部平滑']),
            note='两侧同一份真实200ms点云、同一视角。时间轴播放的是预计算结果；重建耗时另行实测，不是播放帧率。没有历史累积、全墙封面、位姿或动态分割。实测点模式显示窗口内全部有效点。',
            feature_note='绿色为可信局部平坦面，橙色为边缘；局部显示平滑最大6mm＋每米0.5mm。投票平面只恢复角度候选中的小缺口，并检查实际邻近射线支持和遮挡冲突；不做整墙凸包封面。未知空白保持未知。'),
        limitations=['Only current 200ms returns; no whole-plane hull, SLAM or map accumulation',
            'Meshes interpolate visible returns; openings have no semantic ground truth',
            'Reconstruction timing excludes file reading, evaluation and browser rendering',
            'CPU speed measured on this PC; not a Pi or FPGA result'])
    (args.out/'manifest.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    print('OUTPUT',args.out)


if __name__=='__main__':main()
