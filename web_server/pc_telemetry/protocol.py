from __future__ import annotations

import enum
import struct
import zlib
from dataclasses import dataclass
from typing import Any


MAGIC = b"M3TL"
VERSION = 1
MAX_PAYLOAD = 1024
HEADER = struct.Struct("<4sBBHIIQII")
HEADER_SIZE = HEADER.size
MAX_FRAME = HEADER_SIZE + MAX_PAYLOAD


class MessageType(enum.IntEnum):
    HEARTBEAT = 1
    CHASSIS = 2
    TARGETS = 3
    CAMERA_STATUS = 4


class FrameError(ValueError):
    pass


@dataclass(frozen=True)
class Frame:
    message_type: MessageType
    flags: int
    sequence: int
    timestamp_ms: int
    payload: bytes


HEARTBEAT = struct.Struct("<QIIII")
CHASSIS = struct.Struct("<BBHhhhHiiI")
TARGETS_HEAD = struct.Struct("<BBH")
TARGET = struct.Struct("<BBhhhhhhH")
CAMERA_STATUS = struct.Struct("<BBHHHII")


def _crc32(data: bytes) -> int:
    return zlib.crc32(data) & 0xFFFFFFFF


def encode_frame(
    message_type: MessageType | int,
    payload: bytes,
    sequence: int,
    timestamp_ms: int,
    flags: int = 0,
) -> bytes:
    payload = bytes(payload)
    if len(payload) > MAX_PAYLOAD:
        raise FrameError(f"payload too long: {len(payload)}")
    try:
        mtype = MessageType(message_type)
    except ValueError as exc:
        raise FrameError(f"unknown message type: {message_type}") from exc
    prefix = struct.pack(
        "<4sBBHIIQ",
        MAGIC,
        VERSION,
        int(mtype),
        flags & 0xFFFF,
        len(payload),
        sequence & 0xFFFFFFFF,
        timestamp_ms & 0xFFFFFFFFFFFFFFFF,
    )
    return prefix + struct.pack("<II", _crc32(prefix), _crc32(payload)) + payload


def decode_frame(datagram: bytes) -> Frame:
    if len(datagram) < HEADER_SIZE:
        raise FrameError("short header")
    magic, version, raw_type, flags, payload_len, sequence, timestamp_ms, header_crc, payload_crc = HEADER.unpack_from(datagram)
    if magic != MAGIC:
        raise FrameError("bad magic")
    if version != VERSION:
        raise FrameError(f"unsupported version: {version}")
    try:
        message_type = MessageType(raw_type)
    except ValueError as exc:
        raise FrameError(f"unknown message type: {raw_type}") from exc
    if payload_len > MAX_PAYLOAD:
        raise FrameError(f"payload too long: {payload_len}")
    expected = HEADER_SIZE + payload_len
    if len(datagram) != expected:
        raise FrameError(f"length mismatch: got {len(datagram)}, expected {expected}")
    if _crc32(datagram[:24]) != header_crc:
        raise FrameError("header CRC mismatch")
    payload = datagram[HEADER_SIZE:]
    if _crc32(payload) != payload_crc:
        raise FrameError("payload CRC mismatch")
    return Frame(message_type, flags, sequence, timestamp_ms, payload)


def parse_payload(frame: Frame) -> dict[str, Any]:
    payload = frame.payload
    if frame.message_type is MessageType.HEARTBEAT:
        if len(payload) != HEARTBEAT.size:
            raise FrameError("bad heartbeat length")
        uptime_ms, tx_ok, tx_dropped, link_errors, build_id = HEARTBEAT.unpack(payload)
        return {"uptime_ms": uptime_ms, "tx_ok": tx_ok, "tx_dropped": tx_dropped,
                "link_errors": link_errors, "build_id": build_id}

    if frame.message_type is MessageType.CHASSIS:
        if len(payload) != CHASSIS.size:
            raise FrameError("bad chassis length")
        valid, status_flags, _reserved, yaw, vx, vy, rx_errors, x_mm, y_mm, car_ms = CHASSIS.unpack(payload)
        return {"valid": bool(valid), "status_flags": status_flags,
                "yaw_q10000": yaw, "body_vx_q5000": vx, "body_vy_q5000": vy,
                "rx_error_count": rx_errors, "world_x_mm": x_mm,
                "world_y_mm": y_mm, "car_time_ms": car_ms}

    if frame.message_type is MessageType.TARGETS:
        if len(payload) < TARGETS_HEAD.size:
            raise FrameError("short targets payload")
        count, overflow, _reserved = TARGETS_HEAD.unpack_from(payload)
        if count > 32:
            raise FrameError(f"too many targets: {count}")
        expected = TARGETS_HEAD.size + count * TARGET.size
        if len(payload) != expected:
            raise FrameError(f"bad targets length: got {len(payload)}, expected {expected}")
        objects = []
        for index in range(count):
            values = TARGET.unpack_from(payload, TARGETS_HEAD.size + index * TARGET.size)
            objects.append(dict(zip(
                ("id", "flags", "x_min_mm", "x_max_mm", "y_min_mm", "y_max_mm",
                 "z_min_mm", "z_max_mm", "nearest_mm"), values
            )))
        return {"count": count, "overflow": bool(overflow), "targets": objects}

    if frame.message_type is MessageType.CAMERA_STATUS:
        if len(payload) != CAMERA_STATUS.size:
            raise FrameError("bad camera status length")
        ok, status_flags, width, height, fps_x10, frame_count, vsync_miss = CAMERA_STATUS.unpack(payload)
        return {"ok": bool(ok), "status_flags": status_flags, "width": width,
                "height": height, "fps_x10": fps_x10, "frame_count": frame_count,
                "vsync_miss": vsync_miss}

    raise FrameError("unhandled message type")

