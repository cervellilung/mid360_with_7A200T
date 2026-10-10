"""Bounded MID-360 scan assembler; the processing core never retains a point frame."""

from __future__ import annotations

from dataclasses import dataclass
import numpy as np

from .protocol import Mid360Packet, POINT_DTYPE


@dataclass(frozen=True)
class Scan:
    device_ns: int
    host_ns: int
    points: np.ndarray
    dropped_points: int
    missed_packets: int


class FrameAssembler:
    def __init__(self, max_points: int = 40_000, period_ns: int = 100_000_000):
        self.max_points, self.period_ns = max_points, period_ns
        self._bucket: int | None = None
        self._parts: list[np.ndarray] = []
        self._count = self._dropped = self._missed = 0
        self._first_host = self._first_device = 0
        self._last_host = 0
        self._last_counter: int | None = None

    def add(self, packet: Mid360Packet) -> Scan | None:
        bucket = packet.timestamp_ns // self.period_ns
        ready = self.flush() if self._bucket is not None and bucket != self._bucket else None
        if self._bucket is None:
            self._bucket = bucket
            self._first_host = packet.host_ns
            self._first_device = packet.timestamp_ns
        if self._last_counter is not None:
            delta = (packet.udp_count - self._last_counter) & 0xFFFF
            # Counter may reset at frame boundary; only a small forward gap is loss.
            if 1 < delta < 1000 and ready is None:
                self._missed += delta - 1
        self._last_counter = packet.udp_count
        self._last_host = packet.host_ns
        available = max(0, self.max_points - self._count)
        take = min(available, len(packet.points))
        if take:
            self._parts.append(packet.points[:take])
            self._count += take
        self._dropped += len(packet.points) - take
        return ready

    def flush(self) -> Scan | None:
        if self._bucket is None:
            return None
        points = (np.concatenate(self._parts) if self._parts else
                  np.empty(0, dtype=POINT_DTYPE))
        scan = Scan(self._first_device, self._last_host, points,
                    self._dropped, self._missed)
        self._bucket = None
        self._parts = []
        self._count = self._dropped = self._missed = 0
        return scan
