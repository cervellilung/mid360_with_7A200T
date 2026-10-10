"""Build a local, repeatable car-style preview from a real M3CP recording."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
import time

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT.parent))
from ar_render.m3cp_recording import StreamFile, read_camera_meta
from render_ar_anaglyph import rotate_image, yuyv_to_bgr
from web_server.car_showcase.source import collect_points
from car_showcase.mesh import Mesh, make_mesh

DEFAULT_RECORDING = ROOT.parent / "sample" / "sessions" / "linux_dual_final_01"
DEFAULT_OUTPUT = ROOT.parent / "sample" / "car_showcase" / "output"


from car_showcase.assets import pack, write_json, write_binary


def build(recording: Path, output: Path, seconds: float, sample_hz: float) -> dict:
    output.mkdir(parents=True, exist_ok=True)
    (output / "frames").mkdir(exist_ok=True)
    started = time.perf_counter()
    with StreamFile(recording / "stream_1.bin") as radar, StreamFile(recording / "stream_2.bin") as camera:
        if not radar.entries or not camera.entries:
            raise ValueError("recording needs both radar and camera records")
        base_us = max(radar.times[0], camera.times[0])
        stop_us = min(radar.times[-1], camera.times[-1], base_us + int(seconds * 1e6))
        if stop_us <= base_us:
            raise ValueError("radar and camera timestamps do not overlap")
        cloud, decoded, bad = collect_points(radar, base_us + 1_000_000, 1_000_000)
        static = make_mesh(cloud)
        write_json(output / "static_mesh.json", pack(static))
        np.savez_compressed(output / "static_mesh.npz", vertices=static.vertices,
                            raw_vertices=static.raw_vertices,
                            triangles=static.triangles, normals=static.normals,
                            observed=static.observed)
        frames = []
        count = int(np.floor((stop_us - base_us) / 1e6 * sample_hz))
        for number in range(count + 1):
            capture_us = base_us + round(number * 1e6 / sample_hz)
            if capture_us > stop_us:
                break
            cloud, packets, bad_frame = collect_points(radar, capture_us, 100_000)
            mesh = make_mesh(cloud)
            mesh_name = f"frames/mesh_{number:03d}.m3mesh"
            write_binary(output / mesh_name, mesh)
            camera_index = int(np.searchsorted(camera.times, capture_us))
            camera_index = min(camera_index, len(camera) - 1)
            if camera_index and abs(camera.times[camera_index-1] - capture_us) < abs(camera.times[camera_index] - capture_us):
                camera_index -= 1
            meta, raw = read_camera_meta(camera.payload(camera_index))
            if meta.format != 2 or meta.width != 640 or meta.height != 480 or len(raw) < meta.stride * meta.height:
                raise ValueError(f"unexpected camera record format at {camera_index}: {meta}")
            image = rotate_image(yuyv_to_bgr(raw, meta.width, meta.height, meta.stride), 180)
            image_name = f"frames/camera_{number:03d}.jpg"
            if not cv2.imwrite(str(output / image_name), image, [cv2.IMWRITE_JPEG_QUALITY, 84]):
                raise OSError(f"could not write {image_name}")
            frames.append({"t": round((capture_us - base_us) / 1e6, 3),
                           "mesh": mesh_name, "camera": image_name,
                           "camera_delta_ms": round((camera.times[camera_index] - capture_us) / 1000, 1),
                           "packets": packets, "bad_packets": bad_frame,
                           "stats": pack(mesh)["stats"]})
            if number % 10 == 0:
                print(f"frame {number}/{count}: {len(mesh.triangles)} triangles, {mesh.build_ms:.0f} ms", flush=True)
        manifest = {
            "source": str(recording), "source_kind": "real M3CP recording",
            "static_window_s": 2.0, "frame_window_ms": 200,
            "sample_hz": sample_hz, "duration_s": frames[-1]["t"],
            "camera_calibrated": False, "odom_available": False,
            "static": {"mesh": "static_mesh.json", "stats": pack(static)["stats"],
                       "packets": decoded, "bad_packets": bad},
            "frames": frames,
            "build_s": round(time.perf_counter() - started, 2),
        }
        write_json(output / "manifest.json", manifest)
        return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--recording", type=Path, default=DEFAULT_RECORDING)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--seconds", type=float, default=20.0)
    parser.add_argument("--sample-hz", type=float, default=5.0)
    args = parser.parse_args()
    result = build(args.recording, args.out, args.seconds, args.sample_hz)
    print(f"built {len(result['frames'])} frames in {result['build_s']} s -> {args.out}")


if __name__ == "__main__":
    main()
