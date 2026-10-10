"""Bit-exact contract for new PL motion, snapshots and configuration."""
from __future__ import annotations
from dataclasses import dataclass
from math import isqrt
import struct

@dataclass
class MotionReference:
    last_us: int | None = None
    filtered: int = 0
    distance_um: int = 0
    remainder: int = 0
    rejected: int = 0

    def update(self, vx_raw: int, vy_raw: int, stamp_us: int):
        if self.last_us is not None and not 0 < stamp_us - self.last_us <= 100_000:
            self.rejected += 1
            self.last_us = stamp_us
            return None
        speed = isqrt(vx_raw * vx_raw + vy_raw * vy_raw) // 5
        filtered = speed if self.last_us is None else self.filtered + ((speed - self.filtered) >> 3)
        dt = 0 if self.last_us is None else stamp_us - self.last_us
        area = (self.filtered + filtered) * dt + self.remainder
        self.distance_um += area // 2000
        self.remainder = area % 2000
        self.filtered, self.last_us = filtered, stamp_us
        return speed, filtered, self.distance_um

def decode_snapshot(payload: bytes) -> dict:
    if len(payload) != 416 * 4:
        raise ValueError('snapshot must contain 416 words')
    w = struct.unpack('<416I', payload)
    if w[0] != 0x31524550 or w[1] != 1 or (w[2] & 63) > 32:
        raise ValueError('unsupported perception snapshot')
    signed = lambda v: v if v < 1 << 31 else v - (1 << 32)
    objects = []
    for i in range(w[2] & 63):
        a = w[32 + i * 12:44 + i * 12]
        objects.append({'cells': a[0] >> 16, 'points': a[0] & 65535,
                        'min_xyz_mm': list(map(signed, a[1:4])),
                        'max_xyz_mm': list(map(signed, a[4:7])),
                        'nearest_xy_sq_mm2': a[7] << 32 | a[8],
                        'closest_xyz_mm': list(map(signed, a[9:12])),
                        'distance_mm': isqrt(a[7] << 32 | a[8])})
    return {'radar_valid': bool(w[2] & 64), 'motion_valid': bool(w[2] & 128),
            'calibrated': bool(w[2] & 256), 'test_overlay':bool(w[2]&512), 'radar_us': w[3] | w[4] << 32,
            'speed_mm_s': w[5], 'filtered_mm_s': w[6], 'distance_um': w[7] | w[8] << 32,
            'motion_us': w[9] | w[10] << 32, 'now_us': w[22] | w[23] << 32,
            'source_counters':dict(zip(('fifo_overflow','eth_rejected','odom_bad','odom_busy','radar_slot_drops','chassis_slot_drops'),w[24:30])),
            'objects': objects, 'counters': dict(zip(
                ('accepted', 'roi_rejected', 'ground_rejected', 'point_overflow', 'tap_drops',
                 'bad_packets', 'good_packets', 'crc_unavailable', 'motion_rejected',
                 'motion_overflow', 'publish_drops'), w[11:22]))}
