"""Rebuild meshes from real recording; reuse existing matching camera JPEGs.
Run from repository root: py -m web_server.car_showcase.rebuild_surfaces
No camera, board, cv2, downloads or remote service required.
"""
from pathlib import Path
import argparse
import json
import shutil
import time
import numpy as np
from .assets import pack, write_json, write_binary
from .mesh import make_mesh
from .source import collect_points
from web_server.ar_render.m3cp_recording import StreamFile

ROOT = Path(__file__).resolve().parents[2]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--recording', type=Path, default=ROOT/'sample/sessions/linux_dual_final_01')
    parser.add_argument('--base-cache', type=Path, default=ROOT/'sample/car_showcase/output')
    parser.add_argument('--out', type=Path, default=ROOT/'sample/car_showcase/surface_improved_20261008')
    args = parser.parse_args()
    if args.out.resolve() == args.base_cache.resolve():
        parser.error('keep baseline cache separate')
    old = json.loads((args.base_cache/'manifest.json').read_text(encoding='utf-8'))
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out/'frames').mkdir(exist_ok=True)
    started = time.perf_counter()
    with StreamFile(args.recording/'stream_1.bin') as radar, StreamFile(args.recording/'stream_2.bin') as camera:
        base = max(radar.times[0], camera.times[0])
        cloud, packets, bad = collect_points(radar, base+1_000_000, 1_000_000)
        mesh = make_mesh(cloud)
        write_json(args.out/'static_mesh.json', pack(mesh))
        planar = make_mesh(cloud, planar_fill=True)
        write_json(args.out/'static_planar.json', pack(planar))
        np.savez_compressed(args.out/'static_mesh.npz', vertices=mesh.vertices,
                            raw_vertices=mesh.raw_vertices, triangles=mesh.triangles,
                            normals=mesh.normals, observed=mesh.observed)
        frames = []
        for i, previous in enumerate(old['frames']):
            entry = dict(previous)
            points, n, errors = collect_points(radar, base+round(entry['t']*1e6), 100_000)
            current = make_mesh(points)
            write_binary(args.out/entry['mesh'], current)
            planar_frame = make_mesh(points, planar_fill=True)
            planar_name = entry['mesh'].replace('mesh_', 'planar_')
            write_binary(args.out/planar_name, planar_frame)
            entry.update(planar_mesh=planar_name, planar_stats=pack(planar_frame)['stats'])
            shutil.copyfile(args.base_cache/entry['camera'], args.out/entry['camera'])
            entry.update(stats=pack(current)['stats'], packets=n, bad_packets=errors)
            frames.append(entry)
            if i % 20 == 0:
                print(f"frame {i}/{len(old['frames'])}: {current.build_ms:.1f} ms", flush=True)
        manifest = dict(old)
        manifest.update(source=str(args.recording), surface_algorithm='planar-local-v3',
                        planar_static=dict(mesh='static_planar.json', stats=pack(planar)['stats']),
                        static=dict(mesh='static_mesh.json', stats=pack(mesh)['stats'],
                                    packets=packets, bad_packets=bad), frames=frames,
                        build_s=round(time.perf_counter()-started, 2),
                        limitations=['Visible surfaces only; open gaps and net holes retained',
                                     'Static 2s accumulation is not real-time performance',
                                     'Camera JPEGs reused at identical recorded timestamps; uncalibrated'])
        write_json(args.out/'manifest.json', manifest)
    print(json.dumps(dict(output=str(args.out), frames=len(frames), static=manifest['static'],
                          build_s=manifest['build_s']), ensure_ascii=False))

if __name__ == '__main__':
    main()
