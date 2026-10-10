"""Real corridor recording -> baseline/angular cache, screenshots and report.

No hardware access. All windows end at the selected playback time. 2 s windows
retain moving-person trails and are explicitly labelled accumulated data.
"""
from pathlib import Path
import argparse
from dataclasses import asdict
import json
import time
import numpy as np
from PIL import Image
from web_server.pc_perception.session import SessionReader
from web_server.pc_perception.protocol import decode_mid360, PacketError
from .mesh import make_mesh
from .adaptive_mesh import make_angular_mesh, AngularConfig
from .feature_mesh import make_feature_mesh
from .assets import pack, write_binary
from .analyze_corridor import png

ROOT = Path(__file__).resolve().parents[2]


def metrics(mesh):
    used = np.zeros(len(mesh.vertices), bool)
    used[np.unique(mesh.triangles)] = True
    radius = np.linalg.norm(mesh.raw_vertices, axis=1)
    groups = []
    for lo, hi in ((0, 2), (2, 4), (4, 8), (8, 12)):
        mask = (radius >= lo) & (radius < hi) & mesh.observed
        n = int(mask.sum())
        groups.append(dict(range_m=[lo, hi], measured=n, attached=int((used & mask).sum()),
                           coverage=round(float((used & mask).sum()/max(n, 1)), 4)))
    return dict(**pack(mesh)['stats'], attached_vertices=int((used & mesh.observed).sum()),
                range_bins=groups, diagnostics=getattr(mesh, 'diagnostics', {}),
                coverage_scope='measured vertices used by faces; not complete physical surface area')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--recording', type=Path, default=ROOT/'sample/radar/corridor_dynamic_20261008_direct')
    parser.add_argument('--out', type=Path)
    parser.add_argument('--features', action='store_true', help='Include local-feature refinement as a third variant')
    parser.add_argument('--sample-hz', type=float, default=2)
    args = parser.parse_args()
    args.out = args.out or ROOT/'sample/car_showcase'/('feature_corridor_20261009' if args.features else 'angular_corridor_20261009')
    if not (0 < args.sample_hz <= 10):
        parser.error('sample-hz must be in (0, 10]')
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out/'frames').mkdir(exist_ok=True)
    chunks, stamps = [], []
    bad = crc = gaps = 0
    last = None
    for event in SessionReader(args.recording):
        try:
            packet = decode_mid360(event.payload, event.host_ns)
        except PacketError:
            bad += 1
            continue
        if last is not None and packet.udp_count != (last+1) & 65535:
            gaps += 1
        last = packet.udp_count
        crc += int(packet.crc_present)
        stamps.append(event.host_ns)
        chunks.append(np.column_stack([packet.points[k] for k in ('x', 'y', 'z')]))
    if not chunks:
        raise ValueError('recording contains no valid radar packets')
    times = (np.asarray(stamps, np.int64)-stamps[0])/1e9
    duration = float(times[-1])
    def points(t, width):
        low, high = np.searchsorted(times, [max(0, t-width), t], side='right')
        if low == high:
            return np.empty((0, 3), np.int32)
        return np.concatenate(chunks[low:high])
    config = AngularConfig()
    variant_names = ['baseline', 'angular'] + (['feature'] if args.features else [])
    def variants(cloud):
        original = make_mesh(cloud)
        angular = make_angular_mesh(cloud, include_geometry=args.features)
        result = [('baseline', original), ('angular', angular)]
        if args.features:
            result.append(('feature', make_feature_mesh(cloud, base=angular)))
        return result
    started = time.perf_counter()
    entries = []
    # Six static comparisons plus bounded 200 ms replay; no long-window replay
    # disguised as a current dynamic object reconstruction.
    comparisons = {}
    for width in (.1, .2, 2.):
        cloud = points(7., width)
        pair = {}
        for name, mesh in variants(cloud):
            stem = f'{name}_{int(width*1000)}ms'
            write_binary(args.out/(stem+'.m3mesh'), mesh)
            np.savez_compressed(args.out/(stem+'.npz'), vertices=mesh.vertices, raw_vertices=mesh.raw_vertices,
                                triangles=mesh.triangles, normals=mesh.normals, observed=mesh.observed,
                                features=getattr(mesh, 'features', np.zeros(len(mesh.vertices), np.uint8)))
            png(mesh, cloud, args.out/(stem+'.png'), f'{name} / t=7s / {int(width*1000)}ms')
            pair[name] = dict(mesh=stem+'.m3mesh', image=stem+'.png', stats=metrics(mesh))
            if hasattr(mesh, 'features'):
                mesh.features.tofile(args.out/(stem+'.features'))
                pair[name]['features'] = stem+'.features'
        comparisons[str(int(width*1000))] = pair
        images = [Image.open(args.out/(f'{name}_{int(width*1000)}ms.png')) for name in variant_names]
        combined = Image.new('RGB', (images[0].width*len(images), images[0].height))
        for i, im in enumerate(images):
            combined.paste(im, (i*im.width, 0))
        combined.save(args.out/f'comparison_{int(width*1000)}ms.png')
    for i, t in enumerate(np.arange(.5, duration+.001, 1/args.sample_hz)):
        cloud = points(float(t), .2)
        entry = dict(t=round(float(t), 3), variants={})
        for name, mesh in variants(cloud):
            filename = f'frames/{name}_{i:03d}.m3mesh'
            write_binary(args.out/filename, mesh)
            entry['variants'][name] = dict(mesh=filename, stats=metrics(mesh))
            if hasattr(mesh, 'features'):
                feature_path = f'frames/feature_{i:03d}.features'
                mesh.features.tofile(args.out/feature_path)
                entry['variants'][name]['features'] = feature_path
        entries.append(entry)
        if i % 10 == 0:
            print(f'frame {i}: t={t:.1f}s', flush=True)
    report = dict(source=str(args.recording), packets=len(chunks), bad_packets=bad,
                  counter_discontinuities=gaps, crc_present=crc, duration_s=duration,
                  algorithm='local_feature_v1' if args.features else 'adaptive_angular_v1',
                  variants=variant_names, config=asdict(config), comparisons=comparisons,
                  frames=entries, sample_hz=args.sample_hz, build_s=round(time.perf_counter()-started, 2),
                  default=dict(mode='comparison', algorithm='angular', window_ms=200, time_s=7),
                  limitations=['Real corridor recording with walking person; pose not verified',
                               'No dynamic segmentation; 2 s accumulation can retain trails',
                               'Only visible returns within 12 m; surfaces between samples are interpolation',
                               'Feature refinement preserves raw measurements but bounded display positions may differ',
                               'Vertex coverage is not ground-truth surface coverage',
                               'Network data source, not an FPGA meshing or Pi performance result'])
    (args.out/'manifest.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(dict(output=str(args.out), build_s=report['build_s'], packets=len(chunks),
                         comparisons={k:{n:v['stats'] for n,v in pair.items()} for k,pair in comparisons.items()})))


if __name__ == '__main__':
    main()
