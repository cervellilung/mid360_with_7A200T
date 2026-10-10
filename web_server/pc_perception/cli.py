"""User-run entry points. Importing this module never touches local hardware."""

from __future__ import annotations

import argparse
from dataclasses import asdict
import json
from pathlib import Path
import time

from .calibration import (camera_intrinsics, estimate_time_offset,
                          fit_ground_plane, save_calibration, solve_extrinsics)
from .grid import GridConfig
from .pipeline import PerceptionPipeline
from .projection import Calibration
from .session import SessionWriter
from .sources import LiveSource, ReplaySource, SyntheticSource
from .session import SessionReader, RADAR
from .protocol import decode_mid360, PacketError
from .vectors import export_vectors, synthetic_calibration


def _json(path: str) -> object:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def _write_json(path: str, value: object) -> None:
    out = Path(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(value, indent=2, ensure_ascii=False), encoding="utf-8")


def _run(args) -> int:
    config = GridConfig.load(args.config) if args.config else GridConfig()
    cal = Calibration.load(args.calibration) if args.calibration else None
    if args.command == "simulate":
        source = SyntheticSource(args.duration)
        cal = synthetic_calibration()
        camera_id = mount_id = "synthetic"
    elif args.command == "replay":
        source = ReplaySource(args.session, args.speed)
        camera_id, mount_id = args.camera_id, args.mount_id
    else:
        if (args.command == "live" and args.camera_index < 0) or not args.lidar_ip:
            raise ValueError("live mode requires --camera-index and --lidar-ip")
        camera_index = None if args.command == "radar" else args.camera_index
        source = LiveSource(camera_index, args.lidar_ip, args.bind_ip,
                            args.udp_port, args.serial_port, args.baud).open()
        camera_id, mount_id = args.camera_id, args.mount_id
    recorder = None
    if args.record:
        recorder = SessionWriter(args.record, {"mode": args.command,
                         "camera_id": camera_id, "mount_id": mount_id,
                         "grid_config": asdict(config), "calibration_path": args.calibration})
    offset = int(_json(args.time_offset)["host_minus_device_ns"]) if args.time_offset else None
    pipeline = PerceptionPipeline(config, cal, camera_id, mount_id, recorder, offset)
    if not args.headless:
        from .ui import run_ui
        return run_ui(source, pipeline, title=f"MID-360 prototype - {args.command}",
                      radar_only=args.command == "radar")
    deadline = time.monotonic() + args.duration if args.command == "radar" else None
    try:
        while not getattr(source, "finished", False) and (deadline is None or time.monotonic() < deadline):
            for event in source.poll():
                pipeline.ingest(event)
            time.sleep(0.005)
    except KeyboardInterrupt:
        pass
    finally:
        source.close()
        pipeline.finish(flush_partial=args.command != "radar")
    report = pipeline.status(time.monotonic_ns())
    if args.command == "radar":
        report["last_scan"] = {
            "accepted_points": pipeline.latest_result.accepted_points,
            "overflow_points": pipeline.latest_result.overflow_points,
            "detections": [{"distance_mm": d.distance_mm,
                            "closest_xyz_mm": d.closest_xyz_mm,
                            "cells": d.cells, "points": d.points}
                           for d in pipeline.latest_result.detections]
        } if pipeline.latest_result else None
    print(json.dumps(report, indent=2))
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="MID-360 / camera FPGA-oriented PC prototype")
    sub = ap.add_subparsers(dest="command", required=True)
    for command in ("simulate", "replay", "live", "radar"):
        p = sub.add_parser(command)
        p.add_argument("--headless", action="store_true", help="process without Qt window")
        p.add_argument("--record", help="new recording directory")
        p.add_argument("--config", help="integer-grid JSON configuration")
        p.add_argument("--calibration", help="validated extrinsic calibration JSON")
        p.add_argument("--time-offset", help="radar device to host monotonic offset JSON")
        p.add_argument("--camera-id", default="", help="explicit stable camera identifier")
        p.add_argument("--mount-id", default="", help="explicit mount identifier")
        if command in ("simulate", "radar"):
            p.add_argument("--duration", type=float, default=30.0)
        if command == "replay":
            p.add_argument("session")
            p.add_argument("--speed", type=float, default=1.0)
        if command in ("live", "radar"):
            if command == "live":
                p.add_argument("--camera-index", type=int, required=True)
            p.add_argument("--lidar-ip", required=True)
            p.add_argument("--bind-ip", default="0.0.0.0")
            p.add_argument("--udp-port", type=int, default=56301)
            p.add_argument("--serial-port")
            p.add_argument("--baud", type=int, default=460800)
    p = sub.add_parser("calibrate-camera")
    p.add_argument("--images", required=True, help="directory of checkerboard images")
    p.add_argument("--columns", type=int, default=9, help="inner corners")
    p.add_argument("--rows", type=int, default=6, help="inner corners")
    p.add_argument("--square-mm", type=float, default=25.0)
    p.add_argument("--out", required=True)
    p = sub.add_parser("capture-checkerboard")
    p.add_argument("--camera-index", type=int, required=True)
    p.add_argument("--out", required=True, help="image directory")
    p = sub.add_parser("calibrate-extrinsics")
    p.add_argument("--intrinsics", required=True)
    p.add_argument("--matches", required=True, help="JSON [{lidar_mm:[x,y,z],pixel:[u,v]},...]")
    p.add_argument("--camera-id", required=True)
    p.add_argument("--mount-id", required=True)
    p.add_argument("--out", required=True)
    p = sub.add_parser("calibrate-ground")
    p.add_argument("--points", required=True, help="JSON array of selected ground xyz millimetres")
    p.add_argument("--out", required=True)
    p = sub.add_parser("calibrate-time")
    times = p.add_mutually_exclusive_group(required=True)
    times.add_argument("--pairs", help="JSON [{device_ns,host_ns},...]")
    times.add_argument("--session", help="recorded session with at least 20 valid radar packets")
    p.add_argument("--out", required=True)
    p = sub.add_parser("pick-correspondences")
    p.add_argument("--sessions", nargs="+", required=True, help="one or more static recording directories")
    p.add_argument("--matches-out", required=True)
    p.add_argument("--ground-out", required=True)
    p = sub.add_parser("export-vectors")
    p.add_argument("--out", required=True)
    args = ap.parse_args(argv)
    if args.command in ("simulate", "replay", "live", "radar"):
        return _run(args)
    if args.command == "calibrate-camera":
        paths = sorted(Path(args.images).glob("*"))
        _write_json(args.out, camera_intrinsics(paths, args.columns, args.rows, args.square_mm))
    elif args.command == "capture-checkerboard":
        from .camera_capture import capture_checkerboard
        return capture_checkerboard(args.camera_index, args.out)
    elif args.command == "calibrate-extrinsics":
        cal = solve_extrinsics(_json(args.matches), _json(args.intrinsics),
                               args.camera_id, args.mount_id)
        save_calibration(cal, args.out)
        print(f"reprojection p95={cal.reprojection_p95_px:.2f}px valid={cal.valid}")
    elif args.command == "calibrate-ground":
        plane = fit_ground_plane(_json(args.points))
        residual = plane.pop("residual_p95_mm")
        _write_json(args.out, asdict(GridConfig(**plane)))
        print(f"ground plane residual p95={residual:.1f} mm")
    elif args.command == "calibrate-time":
        if args.pairs:
            pairs = _json(args.pairs)
        else:
            pairs = []
            for event in SessionReader(args.session):
                if event.kind == RADAR:
                    try:
                        p = decode_mid360(event.payload, event.host_ns)
                        pairs.append({"device_ns": p.timestamp_ns, "host_ns": p.host_ns})
                    except PacketError:
                        pass
        _write_json(args.out, estimate_time_offset(pairs))
    elif args.command == "pick-correspondences":
        from .picker import run_picker
        return run_picker([Path(p) for p in args.sessions], Path(args.matches_out), Path(args.ground_out))
    elif args.command == "export-vectors":
        export_vectors(args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
