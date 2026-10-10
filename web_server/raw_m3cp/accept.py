"""Check an actual three-stream acquisition before using it for optimisation."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from .replay import stream_records
from .wire import CAMERA, CHASSIS, PORTS, RADAR, FLAG_SYNTHETIC


def assess(session: Path, min_camera_fps: float = 25.0) -> dict:
    report = json.loads((session / "report.json").read_text(encoding="utf-8"))
    results: dict[str, object] = {"session": str(session), "streams": {}}
    failures: list[str] = []
    for kind in PORTS:
        count = synthetic = max_gap = 0
        first = previous = None
        for record in stream_records(session / f"stream_{kind}.bin", kind):
            if first is None:
                first = record.capture_us
            if previous is not None:
                gap = record.capture_us - previous
                if gap < 0:
                    failures.append(f"stream {kind}: nonmonotonic capture timestamps")
                max_gap = max(max_gap, gap)
            previous = record.capture_us
            count += 1
            synthetic += bool(record.flags & FLAG_SYNTHETIC)
        interval_us = previous - first if first is not None and previous is not None else 0
        detail = {"records": count, "synthetic": synthetic,
                  "first_us": first, "last_us": previous,
                  "max_gap_ms": max_gap / 1000,
                  "rate_hz": (count - 1) * 1_000_000 / interval_us if interval_us > 0 else 0}
        results["streams"][str(kind)] = detail
        if not count:
            failures.append(f"stream {kind}: no data")
        if synthetic:
            failures.append(f"stream {kind}: synthetic data")
        if report["streams"][str(kind)]["bad"]:
            failures.append(f"stream {kind}: bad records")
        if report["streams"][str(kind)]["missing"]:
            failures.append(f"stream {kind}: missing sequence numbers")
    camera = results["streams"][str(CAMERA)]
    if camera["rate_hz"] < min_camera_fps:
        failures.append(f"camera: {camera['rate_hz']:.2f} fps below {min_camera_fps:.2f}")
    if camera["max_gap_ms"] > 100:
        failures.append("camera: frame gap exceeds 100 ms")
    if report["duration_s"] < 30:
        failures.append("recording shorter than 30 s")
    radar = results["streams"][str(RADAR)]
    chassis = results["streams"][str(CHASSIS)]
    if radar["first_us"] is not None and camera["first_us"] is not None:
        if radar["first_us"] - camera["first_us"] > 12_000_000:
            failures.append("radar first packet more than 12 s after camera first frame")
    if chassis["max_gap_ms"] > 1000:
        failures.append("chassis gap exceeds 1 s")
    results["failures"] = failures
    results["pass"] = not failures
    return results


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("session", type=Path)
    parser.add_argument("--min-camera-fps", type=float, default=25.0)
    args = parser.parse_args()
    outcome = assess(args.session, args.min_camera_fps)
    print(json.dumps(outcome, ensure_ascii=False, indent=2))
    raise SystemExit(0 if outcome["pass"] else 1)


if __name__ == "__main__":
    main()
