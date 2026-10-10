"""DFLink v3 framing and integer Q16 complementary attitude reference."""

from __future__ import annotations

from dataclasses import dataclass
from math import isqrt
import struct


Q16 = 1 << 16
_ATAN_Q16 = (51472, 30386, 16055, 8150, 4091, 2047, 1024, 512,
             256, 128, 64, 32, 16, 8, 4, 2, 1)


def _atan2_q16(y: int, x: int) -> int:
    if x == 0 and y == 0:
        return 0
    # CORDIC vectoring works with x >= 0; bring negative-x angles into range.
    offset = 0
    if x < 0:
        x, y = -x, -y
        offset = 205887 if y <= 0 else -205887  # +/- pi Q16 after negation
    scale = 1 << 16
    vx, vy = x * scale, y * scale
    angle = 0
    for step, table_angle in enumerate(_ATAN_Q16):
        if vy > 0:
            vx, vy = vx + (vy >> step), vy - (vx >> step)
            angle += table_angle
        else:
            vx, vy = vx - (vy >> step), vy + (vx >> step)
            angle -= table_angle
    return angle + offset


@dataclass(frozen=True)
class Odom:
    host_ns: int
    attitude_raw: tuple[int, int, int]
    acceleration_raw: tuple[int, int, int]
    gyro_raw: tuple[int, int, int]
    body_velocity_raw: tuple[int, int, int]
    world_velocity_raw: tuple[int, int, int]
    position_raw: tuple[int, int, int]
    time_ms: int
    time_us: int


def build_odom_subscription(hz_code: int = 0x0A, continuous: bool = True) -> bytes:
    body = bytes((0xDF, 0x01, 0x97, 0x04, 0x80, 0x02,
                  0x01 if continuous else 0x00, hz_code, 0xFD))
    return body + struct.pack("<H", sum(body) & 0xFFFF)


def decode_odom_frame(frame: bytes, host_ns: int = 0) -> Odom:
    if len(frame) != 60 or frame[:1] != b"\xdf" or frame[5] != 51 or frame[57] != 0xFD:
        raise ValueError("invalid Odom v4 frame length or markers")
    if frame[3:5] != b"\x6c\x80" or frame[6] != 4:
        raise ValueError("not an Odom v4 response")
    if sum(frame[:-2]) & 0xFFFF != struct.unpack_from("<H", frame, 58)[0]:
        raise ValueError("DFLink checksum mismatch")
    att = struct.unpack_from("<3h", frame, 7)
    acc = struct.unpack_from("<3h", frame, 13)
    gyro = struct.unpack_from("<3h", frame, 19)
    body = struct.unpack_from("<3h", frame, 25)
    world = struct.unpack_from("<3h", frame, 31)
    pos = struct.unpack_from("<3i", frame, 37)
    ms, us = struct.unpack_from("<2I", frame, 49)
    return Odom(host_ns, att, acc, gyro, body, world, pos, ms, us)


class DFLinkStream:
    def __init__(self):
        self.buffer = bytearray()
        self.bad_frames = 0

    def feed(self, data: bytes, host_ns: int) -> list[Odom]:
        self.buffer.extend(data)
        result = []
        while self.buffer:
            index = self.buffer.find(0xDF)
            if index < 0:
                self.buffer.clear()
                break
            if index:
                del self.buffer[:index]
            if len(self.buffer) < 6:
                break
            length = self.buffer[5]
            total = length + 9
            if total > 265:
                del self.buffer[0]
                self.bad_frames += 1
                continue
            if len(self.buffer) < total:
                break
            candidate = bytes(self.buffer[:total])
            try:
                if candidate[3:5] == b"\x6c\x80":
                    result.append(decode_odom_frame(candidate, host_ns))
                elif candidate[-3] != 0xFD or (sum(candidate[:-2]) & 0xFFFF) != struct.unpack_from("<H", candidate, total-2)[0]:
                    raise ValueError("bad DFLink frame")
                del self.buffer[:total]
            except ValueError:
                del self.buffer[0]
                self.bad_frames += 1
        return result


@dataclass(frozen=True)
class Attitude:
    roll_q16: int
    pitch_q16: int
    yaw_q16: int


class IntegerAttitude:
    def __init__(self, alpha_q16: int = 64225):
        self.alpha_q16 = alpha_q16
        self.current = Attitude(0, 0, 0)
        self.last_host_ns: int | None = None

    def update(self, odom: Odom) -> Attitude:
        ax, ay, az = odom.acceleration_raw
        gx, gy, gz = odom.gyro_raw
        dt_us = 0 if self.last_host_ns is None else max(0, min(100_000, (odom.host_ns-self.last_host_ns)//1000))
        self.last_host_ns = odom.host_ns
        # Gyro raw units: rad/s * 1800.
        increments = tuple(g * dt_us * Q16 // 1_800_000_000 for g in (gx, gy, gz))
        roll_gyro = self.current.roll_q16 + increments[0]
        pitch_gyro = self.current.pitch_q16 + increments[1]
        yaw = self.current.yaw_q16 + increments[2]
        if ax == ay == az == 0:
            self.current = Attitude(roll_gyro, pitch_gyro, yaw)
            return self.current
        roll_acc = _atan2_q16(ay, az)
        pitch_acc = _atan2_q16(-ax, isqrt(ay*ay + az*az))
        a = self.alpha_q16
        self.current = Attitude((a*roll_gyro + (Q16-a)*roll_acc)//Q16,
                                (a*pitch_gyro + (Q16-a)*pitch_acc)//Q16, yaw)
        return self.current
