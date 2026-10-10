"""Versioned lossless event order with raw UDP/serial and JPEG camera frames."""

from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
import struct


MAGIC = b"PCSESS1\n"
HEADER = struct.Struct("<BQI")  # event type, host monotonic ns, payload bytes
RADAR, CAMERA, ODOM = 1, 2, 3
MAX_RECORD_BYTES = 16_000_000


@dataclass(frozen=True)
class Event:
    kind: int
    host_ns: int
    payload: bytes


class SessionWriter:
    def __init__(self, directory: str | Path, metadata: dict):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=False)
        (self.directory / "metadata.json").write_text(
            json.dumps({"format_version": 1, **metadata}, indent=2, ensure_ascii=False), encoding="utf-8")
        self.file = (self.directory / "events.bin").open("wb")
        self.file.write(MAGIC)
        self.last_ns = -1

    def write(self, event: Event) -> None:
        if event.kind not in (RADAR, CAMERA, ODOM) or len(event.payload) > MAX_RECORD_BYTES:
            raise ValueError("invalid session record")
        if event.host_ns < self.last_ns:
            raise ValueError("session events must be in timestamp order")
        self.file.write(HEADER.pack(event.kind, event.host_ns, len(event.payload)))
        self.file.write(event.payload)
        self.last_ns = event.host_ns

    def close(self) -> None:
        if not self.file.closed:
            self.file.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


class SessionReader:
    def __init__(self, directory: str | Path):
        self.directory = Path(directory)
        self.metadata = json.loads((self.directory / "metadata.json").read_text(encoding="utf-8"))
        if self.metadata.get("format_version") != 1:
            raise ValueError("unsupported session version")

    def __iter__(self):
        with (self.directory / "events.bin").open("rb") as fh:
            if fh.read(len(MAGIC)) != MAGIC:
                raise ValueError("invalid session magic")
            last_ns = -1
            while head := fh.read(HEADER.size):
                if len(head) != HEADER.size:
                    raise ValueError("truncated session record header")
                kind, host_ns, length = HEADER.unpack(head)
                if kind not in (RADAR, CAMERA, ODOM) or length > MAX_RECORD_BYTES or host_ns < last_ns:
                    raise ValueError("invalid session record")
                payload = fh.read(length)
                if len(payload) != length:
                    raise ValueError("truncated session payload")
                yield Event(kind, host_ns, payload)
                last_ns = host_ns
