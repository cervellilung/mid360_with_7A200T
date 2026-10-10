"""Deterministic input/expected-output vectors for later Verilog comparison."""

from __future__ import annotations

from dataclasses import asdict
import hashlib
import json
from pathlib import Path

from .grid import GridConfig, GridProcessor
from .projection import Calibration, Q16, Q30, project_box, project_point
from .sources import SyntheticSource, make_synthetic_odom
from .protocol import decode_mid360, encode_mid360_for_test
from .odom import DFLinkStream, IntegerAttitude, build_odom_subscription


def synthetic_calibration(width: int = 640, height: int = 480) -> Calibration:
    # LiDAR x forward/y left/z up -> camera x right/y down/z forward.
    r = (0, -Q30, 0, 0, 0, -Q30, Q30, 0, 0)
    return Calibration(width, height, "synthetic", "synthetic", r, (0, 0, 0),
                       400*Q16, 400*Q16, width//2*Q16, height//2*Q16,
                       33, 25, (0,)*(33*25), (0,)*(33*25), 0.0, True)


def export_vectors(output: str | Path) -> dict:
    points = SyntheticSource.scan_points(0)
    config = GridConfig()
    cal = synthetic_calibration()
    result = GridProcessor(config).process(points)
    inputs = [[int(p[k]) for k in ("x", "y", "z", "reflectivity", "tag")] for p in points]
    detections = [asdict(d) | {"distance_mm": d.distance_mm,
                               "box_px": project_box(d, cal)} for d in result.detections]
    raw_packet = encode_mid360_for_test(points[:96], 123_000_000, 7, 3)
    decoded = decode_mid360(raw_packet, 456_000_000)
    odom_raw = make_synthetic_odom(456_000_000)
    odom = DFLinkStream().feed(odom_raw, 456_000_000)[0]
    attitude = IntegerAttitude().update(odom)
    sample_xyz = [(1000, 0, 300), (2000, -500, 400), (3500, 450, 200)]
    projected = []
    errors = []
    for xyz in sample_xyz:
        fixed = project_point(xyz, cal)
        precise = (cal.fx_q16 / Q16 * (-xyz[1]) / xyz[0] + cal.cx_q16 / Q16,
                   cal.fy_q16 / Q16 * (-xyz[2]) / xyz[0] + cal.cy_q16 / Q16)
        projected.append({"xyz_mm": list(xyz), "fixed_px": fixed,
                          "float_px": list(precise)})
        if fixed is not None:
            errors.extend(abs(fixed[k] - precise[k]) for k in range(2))
    data = {"version": 1, "coordinate_unit": "mm", "config": asdict(config),
            "calibration": asdict(cal), "points": inputs,
            "protocol": {"raw_packet_hex": raw_packet.hex(),
                         "expected": {"timestamp_ns": decoded.timestamp_ns,
                                      "udp_count": decoded.udp_count,
                                      "frame_count": decoded.frame_count,
                                      "crc_present": decoded.crc_present,
                                      "point_count": len(decoded.points),
                                      "first_point": [int(decoded.points[0][k]) for k in
                                                      ("x", "y", "z", "reflectivity", "tag")]}},
            "odom": {"subscription_hex": build_odom_subscription().hex(),
                     "raw_frame_hex": odom_raw.hex(),
                     "expected": {"acceleration_raw": list(odom.acceleration_raw),
                                  "attitude_q16": list(asdict(attitude).values())}},
            "projection_vectors": projected,
            "projection_float_fixed_max_error_px": max(errors, default=0.0),
            "expected": {"accepted_points": result.accepted_points,
                         "rejected_roi": result.rejected_roi,
                         "rejected_ground": result.rejected_ground,
                         "grid_counts": result.grid_counts.reshape(-1).tolist(),
                         "detections": detections}}
    serialized = json.dumps(data, sort_keys=True, separators=(",", ":")).encode()
    data["sha256_without_hash"] = hashlib.sha256(serialized).hexdigest()
    out = Path(output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(data, indent=2), encoding="utf-8")
    return data
