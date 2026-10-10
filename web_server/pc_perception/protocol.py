"""Strict MID-360 protocol decoder. Coordinates remain signed integer millimetres."""

from __future__ import annotations

from dataclasses import dataclass
import struct
import zlib

import numpy as np


HEADER_SIZE = 36
POINT_DTYPE = np.dtype([("x", "<i4"), ("y", "<i4"), ("z", "<i4"),
                        ("reflectivity", "u1"), ("tag", "u1")])
_LOW_DTYPE = np.dtype([("x", "<i2"), ("y", "<i2"), ("z", "<i2"),
                       ("reflectivity", "u1"), ("tag", "u1")])
_SPHERICAL_DTYPE = np.dtype([("depth", "<u4"), ("theta", "<u2"), ("phi", "<u2"),
                             ("reflectivity", "u1"), ("tag", "u1")])


class PacketError(ValueError):
    pass


@dataclass(frozen=True)
class Mid360Packet:
    timestamp_ns: int
    host_ns: int
    udp_count: int
    frame_count: int
    time_type: int
    data_type: int
    crc_present: bool
    points: np.ndarray
    raw: bytes


def decode_mid360(raw: bytes, host_ns: int = 0) -> Mid360Packet:
    """Decode official protocol version 0, including CRC-32(timestamp + data).

    Only Cartesian types 1 and 2 enter the hardware reference pipeline. The
    device should be configured for its default type 1 before a live run.
    """
    if len(raw) < HEADER_SIZE:
        raise PacketError("short MID-360 packet")
    if raw[0] != 0:
        raise PacketError("unsupported MID-360 protocol version")
    length, interval, n_points, udp_count = struct.unpack_from("<HHHH", raw, 1)
    if length != len(raw):
        raise PacketError("packet length mismatch")
    frame_count, data_type, time_type = raw[9], raw[10], raw[11]
    if data_type not in (1, 2):
        raise PacketError(f"unsupported point type {data_type}; configure Cartesian output")
    point_size = 14 if data_type == 1 else 8
    if n_points == 0 or HEADER_SIZE + n_points * point_size != length:
        raise PacketError("point count or point size mismatch")
    expected_crc = struct.unpack_from("<I", raw, 24)[0]
    actual_crc = zlib.crc32(raw[28:]) & 0xFFFFFFFF
    # Some real MID-360 firmware streams set this field to zero. Mark it as
    # unavailable, and still validate all structural fields before decoding.
    if expected_crc != 0 and expected_crc != actual_crc:
        raise PacketError("MID-360 CRC32 mismatch")
    if time_type not in (0, 1, 2):
        raise PacketError("unsupported timestamp type")
    timestamp_ns = struct.unpack_from("<Q", raw, 28)[0]
    if interval > 10_000:
        raise PacketError("implausible packet time interval")
    if data_type == 1:
        points = np.frombuffer(raw, dtype=POINT_DTYPE, count=n_points, offset=HEADER_SIZE).copy()
    else:
        low = np.frombuffer(raw, dtype=_LOW_DTYPE, count=n_points, offset=HEADER_SIZE)
        points = np.empty(n_points, dtype=POINT_DTYPE)
        for axis in ("x", "y", "z"):
            points[axis] = low[axis].astype(np.int32) * 10
        points["reflectivity"] = low["reflectivity"]
        points["tag"] = low["tag"]
    return Mid360Packet(timestamp_ns, host_ns, udp_count, frame_count,
                        time_type, data_type, expected_crc != 0, points, raw)


def encode_mid360_for_test(points: np.ndarray, timestamp_ns: int, udp_count: int = 0,
                           frame_count: int = 0) -> bytes:
    """Generate protocol-correct synthetic packets; never sends to hardware."""
    pts = np.asarray(points, dtype=POINT_DTYPE)
    if not 1 <= len(pts) <= 96:
        raise ValueError("synthetic packet requires 1..96 points")
    raw = bytearray(HEADER_SIZE + len(pts) * 14)
    struct.pack_into("<BHHHHBBB", raw, 0, 0, len(raw), 4800, len(pts),
                     udp_count & 0xFFFF, frame_count & 0xFF, 1, 0)
    struct.pack_into("<Q", raw, 28, timestamp_ns)
    raw[HEADER_SIZE:] = pts.tobytes()
    struct.pack_into("<I", raw, 24, zlib.crc32(raw[28:]) & 0xFFFFFFFF)
    return bytes(raw)
