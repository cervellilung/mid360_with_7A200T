"""Reader for the M3CP-v1 recordings written by pc/record.py.

Each stream is one flat file of records: a 48-byte little-endian header followed
by the payload. The header mirrors linux/m3cp.c exactly.

Scanning is done in two passes so a multi-hundred-megabyte camera stream never
has to be held in memory: first an index of (offset, capture time) is built by
seeking over each payload, then individual records are loaded on demand.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import bisect
import struct
import zlib

MAGIC = b"M3CP"
HEADER_SIZE = 48
CAMERA_META_SIZE = 12
RADAR, CAMERA, CHASSIS = 1, 2, 3

# magic, version, kind, flags, sequence, boot_id, capture_us, device_us,
# payload length, payload crc32, header crc32
_HEADER = struct.Struct("<4sBBHIQQQIII")
_META = struct.Struct("<HHHHI")


class RecordingError(ValueError):
    pass


@dataclass(frozen=True)
class Record:
    kind: int
    sequence: int
    boot_id: int
    capture_us: int
    device_us: int
    payload: bytes


@dataclass(frozen=True)
class Entry:
    """One indexed record: where it lives and when it was captured."""

    offset: int
    length: int
    sequence: int
    capture_us: int
    device_us: int


@dataclass(frozen=True)
class CameraMeta:
    width: int
    height: int
    format: int
    stride: int
    frame_id: int


def _parse_header(raw: bytes) -> tuple[int, int, int, int, int, int, int]:
    (magic, version, kind, _flags, sequence, boot_id,
     capture_us, device_us, length, _crc, header_crc) = _HEADER.unpack(raw)
    if magic != MAGIC:
        raise RecordingError("bad record magic")
    if version != 1:
        raise RecordingError(f"unsupported M3CP version {version}")
    if zlib.crc32(raw[:44]) & 0xFFFFFFFF != header_crc:
        raise RecordingError("header crc32 mismatch")
    return kind, sequence, boot_id, capture_us, device_us, length, header_crc


class StreamFile:
    """Indexed access to one M3CP stream file."""

    def __init__(self, path: str | Path):
        self.path = Path(path)
        self.size = self.path.stat().st_size
        self.entries: list[Entry] = []
        self.kinds: set[int] = set()
        self.boot_id = 0
        self._index()
        # One handle for the whole lifetime: rendering loads thousands of small
        # records and reopening the file each time dominates the runtime.
        self._handle = self.path.open("rb")
        self.times = [entry.capture_us for entry in self.entries]

    def close(self) -> None:
        if not self._handle.closed:
            self._handle.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def _index(self) -> None:
        with self.path.open("rb") as handle:
            offset = 0
            while offset + HEADER_SIZE <= self.size:
                handle.seek(offset)
                raw = handle.read(HEADER_SIZE)
                if len(raw) != HEADER_SIZE:
                    raise RecordingError(f"truncated header at {offset}")
                kind, sequence, boot_id, capture_us, device_us, length, _ = _parse_header(raw)
                if offset + HEADER_SIZE + length > self.size:
                    raise RecordingError(f"truncated payload at {offset}")
                self.entries.append(Entry(offset, length, sequence, capture_us, device_us))
                self.kinds.add(kind)
                self.boot_id = boot_id
                offset += HEADER_SIZE + length

    def __len__(self) -> int:
        return len(self.entries)

    def payload(self, index: int) -> bytes:
        entry = self.entries[index]
        self._handle.seek(entry.offset + HEADER_SIZE)
        data = self._handle.read(entry.length)
        if len(data) != entry.length:
            raise RecordingError(f"short read at entry {index}")
        return data

    def read(self, index: int) -> Record:
        entry = self.entries[index]
        return Record(self.kind_of(index), entry.sequence, self.boot_id,
                      entry.capture_us, entry.device_us, self.payload(index))

    def kind_of(self, index: int) -> int:
        """Stream kind, read from the header alone."""
        self._handle.seek(self.entries[index].offset)
        raw = self._handle.read(HEADER_SIZE)
        return _parse_header(raw)[0]

    def window(self, start_us: int, stop_us: int) -> tuple[int, int]:
        """Half-open index range covering [start_us, stop_us]."""
        lo = bisect.bisect_left(self.times, start_us)
        hi = bisect.bisect_right(self.times, stop_us)
        return lo, hi

    def duration_s(self) -> float:
        if len(self.entries) < 2:
            return 0.0
        return (self.entries[-1].capture_us - self.entries[0].capture_us) / 1e6


def read_camera_meta(payload: bytes) -> tuple[CameraMeta, bytes]:
    if len(payload) < CAMERA_META_SIZE:
        raise RecordingError("camera payload shorter than its metadata")
    width, height, fmt, stride, frame_id = _META.unpack_from(payload, 0)
    return CameraMeta(width, height, fmt, stride, frame_id), payload[CAMERA_META_SIZE:]


def describe(directory: str | Path) -> str:
    """Human readable summary of one recording directory."""
    directory = Path(directory)
    lines = [f"recording: {directory}"]
    for name in sorted(directory.glob("stream_*.bin")):
        stream = StreamFile(name)
        kinds = sorted({stream.kind_of(i) for i in range(len(stream))})
        lines.append(f"  {name.name}: {len(stream)} records, {stream.size} bytes, "
                     f"kinds={kinds}, duration={stream.duration_s():.1f}s")
        if kinds == [CAMERA] and len(stream):
            meta, _ = read_camera_meta(stream.payload(0))
            lines.append(f"    camera: {meta.width}x{meta.height} fmt={meta.format} "
                         f"stride={meta.stride} frame_id={meta.frame_id}")
    return "\n".join(lines)


if __name__ == "__main__":
    import sys

    target = sys.argv[1] if len(sys.argv) > 1 else \
        Path(__file__).resolve().parents[2] / "sample" / "sessions" / "linux_dual_final_01"
    print(describe(target))