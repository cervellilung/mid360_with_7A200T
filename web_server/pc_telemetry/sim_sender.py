from __future__ import annotations

import argparse
import socket
import time

from .protocol import CAMERA_STATUS, CHASSIS, HEARTBEAT, TARGET, TARGETS_HEAD, MessageType, encode_frame


def main() -> int:
    parser = argparse.ArgumentParser(description="Send bounded test telemetry without a board")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=46000)
    parser.add_argument("--count", type=int, default=4)
    args = parser.parse_args()

    payloads = (
        (MessageType.HEARTBEAT, lambda now: HEARTBEAT.pack(now, 1, 0, 0, 0x20260923)),
        (MessageType.CHASSIS, lambda _now: CHASSIS.pack(1, 0, 0, 100, 250, 0, 0, 1200, -300, 777)),
        (MessageType.TARGETS, lambda _now: TARGETS_HEAD.pack(1, 0, 0) + TARGET.pack(1, 0, 900, 1200, -300, 100, 50, 700, 950)),
        (MessageType.CAMERA_STATUS, lambda _now: CAMERA_STATUS.pack(1, 0, 800, 480, 300, 1, 0)),
    )
    started = time.monotonic()
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        for sequence in range(args.count):
            now_ms = int((time.monotonic() - started) * 1000)
            message_type, make_payload = payloads[sequence % len(payloads)]
            sock.sendto(encode_frame(message_type, make_payload(now_ms), sequence, now_ms), (args.host, args.port))
            time.sleep(0.05)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
