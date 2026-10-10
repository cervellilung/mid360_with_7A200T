from __future__ import annotations

import argparse
import json
import socket
import time

from .protocol import MAX_FRAME, FrameError, decode_frame, parse_payload


class SequenceTracker:
    def __init__(self) -> None:
        self.last: dict[int, int] = {}
        self.missing = 0
        self.out_of_order = 0

    def observe(self, message_type: int, sequence: int) -> None:
        previous = self.last.get(message_type)
        if previous is not None:
            delta = (sequence - previous) & 0xFFFFFFFF
            if delta == 0 or delta >= 0x80000000:
                self.out_of_order += 1
            elif delta > 1:
                self.missing += delta - 1
        self.last[message_type] = sequence


def receive(bind_ip: str, port: int, duration: float | None = None) -> int:
    tracker = SequenceTracker()
    good = bad = 0
    deadline = None if duration is None else time.monotonic() + duration
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind((bind_ip, port))
        sock.settimeout(0.5)
        print(f"Listening for PS telemetry on {bind_ip}:{port}")
        while deadline is None or time.monotonic() < deadline:
            try:
                datagram, source = sock.recvfrom(MAX_FRAME + 1)
            except socket.timeout:
                continue
            try:
                frame = decode_frame(datagram)
                body = parse_payload(frame)
                tracker.observe(int(frame.message_type), frame.sequence)
                good += 1
                print(json.dumps({"source": source[0], "type": frame.message_type.name,
                                  "sequence": frame.sequence, "timestamp_ms": frame.timestamp_ms,
                                  "data": body}, ensure_ascii=False))
            except FrameError as exc:
                bad += 1
                print(f"DROP {source[0]}:{source[1]}: {exc}")
    print(json.dumps({"good": good, "bad": bad, "missing": tracker.missing,
                      "out_of_order": tracker.out_of_order}))
    return 0 if bad == 0 else 2


def main() -> int:
    parser = argparse.ArgumentParser(description="Receive AC880 PS telemetry UDP frames")
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=46000)
    parser.add_argument("--duration", type=float)
    args = parser.parse_args()
    return receive(args.bind, args.port, args.duration)


if __name__ == "__main__":
    raise SystemExit(main())
