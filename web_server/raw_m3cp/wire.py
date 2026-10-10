"""Versioned framing shared by the acquisition receiver and PS sender.

All integers are little endian.  The CRCs use the IEEE CRC-32 variant in
zlib.  The 48-byte header is sent before each payload on a TCP byte stream.
"""
from __future__ import annotations

from dataclasses import dataclass
import struct
import zlib

MAGIC = b"M3CP"
VERSION = 1
RADAR = 1
CAMERA = 2
CHASSIS = 3
KINDS = (RADAR, CAMERA, CHASSIS)
PORTS = {RADAR: 46101, CAMERA: 46102, CHASSIS: 46103}
MAX_PAYLOAD = {RADAR: 2048, CAMERA: 12 + 800 * 480 * 2, CHASSIS: 512}
HEADER = struct.Struct("<4sBBHIQQQIII")
CAMERA_META = struct.Struct("<HHHHI")  # width,height,pixel_format,stride,frame_id
CAMERA_RGB565 = 1
CAMERA_YUYV = 2
FLAG_SYNTHETIC = 1
FLAG_TRUNCATED = 2
FLAG_BAD_SOURCE = 4


class FrameError(ValueError):
    pass


@dataclass(frozen=True)
class Record:
    kind: int
    flags: int
    sequence: int
    boot_id: int
    capture_us: int
    device_us: int
    payload: bytes


def encode(record: Record) -> bytes:
    payload = bytes(record.payload)
    if record.kind not in KINDS or len(payload) > MAX_PAYLOAD[record.kind]:
        raise FrameError("invalid type or payload size")
    fields = (MAGIC, VERSION, record.kind, record.flags, record.sequence,
              record.boot_id, record.capture_us, record.device_us,
              len(payload), zlib.crc32(payload) & 0xFFFFFFFF)
    prefix = struct.pack("<4sBBHIQQQII", *fields)
    return prefix + struct.pack("<I", zlib.crc32(prefix) & 0xFFFFFFFF) + payload


def decode_header(data: bytes, expected_kind: int | None = None) -> tuple[int, int, int, int, int, int, int, int]:
    if len(data) != HEADER.size:
        raise FrameError("short header")
    magic, version, kind, flags, sequence, boot_id, capture_us, device_us, length, payload_crc, header_crc = HEADER.unpack(data)
    if magic != MAGIC or version != VERSION or kind not in KINDS:
        raise FrameError("bad magic, version, or type")
    if expected_kind is not None and kind != expected_kind:
        raise FrameError("wrong type for port")
    if length > MAX_PAYLOAD[kind]:
        raise FrameError("oversize payload")
    if zlib.crc32(data[:-4]) & 0xFFFFFFFF != header_crc:
        raise FrameError("header CRC mismatch")
    return kind, flags, sequence, boot_id, capture_us, device_us, length, payload_crc


def decode(data: bytes, expected_kind: int | None = None) -> Record:
    kind, flags, sequence, boot_id, capture_us, device_us, length, payload_crc = decode_header(data[:HEADER.size], expected_kind)
    payload = data[HEADER.size:]
    if len(payload) != length:
        raise FrameError("payload length mismatch")
    if zlib.crc32(payload) & 0xFFFFFFFF != payload_crc:
        raise FrameError("payload CRC mismatch")
    if kind == CAMERA:
        if len(payload) < CAMERA_META.size:
            raise FrameError("short camera metadata")
        width, height, pixel_format, stride, _ = CAMERA_META.unpack_from(payload)
        if (width, height, pixel_format, stride) not in (
                (800, 480, CAMERA_RGB565, 1600),
                (640, 480, CAMERA_YUYV, 1280)):
            raise FrameError("unexpected camera format")
        if len(payload) != CAMERA_META.size + stride * height:
            raise FrameError("invalid camera frame size")
    return Record(kind, flags, sequence, boot_id, capture_us, device_us, payload)
