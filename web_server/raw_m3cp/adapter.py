"""Convert a new raw acquisition into the existing PC replay session format.

The original M3CP stream files remain the authoritative, lossless source.
The converted camera events are JPEG previews for the existing PC pipeline.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

PROJECT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_ROOT))

from pc_perception.session import CAMERA, ODOM, RADAR, Event, SessionWriter
from pc_perception.protocol import decode_mid360
from pc_perception.odom import decode_odom_frame

from .replay import replay
from .wire import (RADAR as RAW_RADAR, CAMERA as RAW_CAMERA,
                   CHASSIS as RAW_CHASSIS, CAMERA_META, CAMERA_YUYV,
                   FLAG_SYNTHETIC)


def convert(input_dir: Path, output_dir: Path, allow_synthetic: bool = False) -> dict:
    import cv2
    import numpy as np

    stats = {"radar": 0, "camera": 0, "chassis": 0, "rejected": 0}
    report = json.loads((input_dir / "report.json").read_text(encoding="utf-8"))
    if not allow_synthetic and any(s["synthetic"] for s in report["streams"].values()):
        raise ValueError("session contains synthetic records; pass --allow-synthetic for a test conversion")
    metadata = {"source_format": "M3CP-v1", "source_boot_id": report["boot_id"],
                "camera_conversion": "RGB565 or YUYV to JPEG preview; raw frame remains in source",
                "time_basis": "sender monotonic capture microseconds"}
    with SessionWriter(output_dir, metadata) as writer:
        for record in replay(input_dir):
            if record.flags & FLAG_SYNTHETIC and not allow_synthetic:
                raise ValueError("synthetic record in real capture")
            timestamp_ns = record.capture_us * 1000
            try:
                if record.kind == RAW_RADAR:
                    decode_mid360(record.payload, timestamp_ns)
                    writer.write(Event(RADAR, timestamp_ns, record.payload))
                    stats["radar"] += 1
                elif record.kind == RAW_CHASSIS:
                    decode_odom_frame(record.payload, timestamp_ns)
                    writer.write(Event(ODOM, timestamp_ns, record.payload))
                    stats["chassis"] += 1
                elif record.kind == RAW_CAMERA:
                    width, height, pixel_format, _, _ = CAMERA_META.unpack_from(record.payload)
                    raw = np.frombuffer(record.payload, dtype=np.uint8,
                                        offset=CAMERA_META.size).reshape(height, width, 2)
                    conversion = (cv2.COLOR_YUV2BGR_YUY2 if pixel_format == CAMERA_YUYV
                                  else cv2.COLOR_BGR5652BGR)
                    bgr = cv2.cvtColor(raw, conversion)
                    success, jpeg = cv2.imencode(".jpg", bgr, [cv2.IMWRITE_JPEG_QUALITY, 95])
                    if not success:
                        raise ValueError("JPEG encode failed")
                    writer.write(Event(CAMERA, timestamp_ns, jpeg.tobytes()))
                    stats["camera"] += 1
            except ValueError:
                stats["rejected"] += 1
    (output_dir / "conversion_report.json").write_text(
        json.dumps(stats, indent=2), encoding="utf-8")
    return stats


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--allow-synthetic", action="store_true")
    args = parser.parse_args()
    print(json.dumps(convert(args.input, args.output, args.allow_synthetic), indent=2))


if __name__ == "__main__":
    main()
