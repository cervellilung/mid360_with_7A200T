"""Deterministic, timestamp-ordered replay of an acquisition session."""
from __future__ import annotations

import argparse
import heapq
import json
from pathlib import Path
from .wire import HEADER, PORTS, Record, FrameError, decode, decode_header


def stream_records(path: Path, kind: int):
    with path.open("rb") as source:
        while header := source.read(HEADER.size):
            if len(header) != HEADER.size:
                raise FrameError(f"truncated header: {path}")
            _, _, _, _, _, _, length, _ = decode_header(header, kind)
            payload = source.read(length)
            if len(payload) != length:
                raise FrameError(f"truncated payload: {path}")
            yield decode(header + payload, kind)


def replay(directory: str | Path):
    root = Path(directory)
    if not (root / "report.json").exists():
        raise FileNotFoundError(root / "report.json")
    sources = [iter(stream_records(root / f"stream_{kind}.bin", kind)) for kind in PORTS]
    queue = []
    for index, source in enumerate(sources):
        first = next(source, None)
        if first is not None:
            heapq.heappush(queue, (first.capture_us, first.kind, first.sequence, index, first))
    last_us = -1
    while queue:
        _, _, _, index, record = heapq.heappop(queue)
        if record.capture_us < last_us:
            raise FrameError("out-of-order capture timestamp")
        last_us = record.capture_us
        yield record
        following = next(sources[index], None)
        if following is not None:
            heapq.heappush(queue, (following.capture_us, following.kind,
                                   following.sequence, index, following))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("session", type=Path)
    args = parser.parse_args()
    counts = dict.fromkeys(PORTS, 0)
    first = last = None
    for record in replay(args.session):
        counts[record.kind] += 1
        if first is None:
            first = record.capture_us
        last = record.capture_us
    print(json.dumps({"counts": counts, "first_capture_us": first,
                      "last_capture_us": last}, indent=2))


if __name__ == "__main__":
    main()
