"""Explicit live source, recorded source, and deterministic synthetic source."""

from __future__ import annotations

import socket
import struct
import time
from pathlib import Path

import numpy as np

from .protocol import POINT_DTYPE, encode_mid360_for_test
from .session import Event, RADAR, CAMERA, ODOM, SessionReader


def encode_camera(frame: np.ndarray) -> bytes:
    import cv2
    ok, encoded = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 92])
    if not ok:
        raise RuntimeError("camera JPEG encoding failed")
    return encoded.tobytes()


def decode_camera(blob: bytes) -> np.ndarray:
    import cv2
    frame = cv2.imdecode(np.frombuffer(blob, np.uint8), cv2.IMREAD_COLOR)
    if frame is None:
        raise ValueError("camera JPEG decoding failed")
    return frame


class LiveSource:
    """Construction is side-effect free; open() only runs from explicit live CLI."""

    def __init__(self, camera_index: int | None, source_ip: str, bind_ip: str,
                 udp_port: int, serial_port: str | None = None, baud: int = 460800,
                 width: int = 640, height: int = 480):
        self.camera_index, self.source_ip = camera_index, source_ip
        self.bind_ip, self.udp_port = bind_ip, udp_port
        self.serial_port, self.baud = serial_port, baud
        self.width, self.height = width, height
        self.sock = self.camera = self.serial = None
        self.last_camera_ns = 0

    def open(self):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8*1024*1024)
        try:
            self.sock.bind((self.bind_ip, self.udp_port))
            self.sock.setblocking(False)
            if self.camera_index is not None:
                import cv2
                self.camera = cv2.VideoCapture(self.camera_index, cv2.CAP_DSHOW if hasattr(cv2, "CAP_DSHOW") else cv2.CAP_ANY)
                if not self.camera.isOpened():
                    raise RuntimeError(f"camera {self.camera_index} could not be opened")
                self.camera.set(cv2.CAP_PROP_FRAME_WIDTH, self.width)
                self.camera.set(cv2.CAP_PROP_FRAME_HEIGHT, self.height)
            if self.serial_port:
                import serial
                from .odom import build_odom_subscription
                self.serial = serial.Serial(self.serial_port, self.baud, timeout=0)
                self.serial.write(build_odom_subscription())
        except Exception:
            self.close()
            raise
        return self

    def poll(self) -> list[Event]:
        events = []
        if self.sock is not None:
            for _ in range(256):
                try:
                    payload, addr = self.sock.recvfrom(65535)
                except BlockingIOError:
                    break
                if addr[0] == self.source_ip:
                    events.append(Event(RADAR, time.monotonic_ns(), payload))
        if self.serial is not None:
            incoming = self.serial.read(self.serial.in_waiting or 0)
            if incoming:
                events.append(Event(ODOM, time.monotonic_ns(), incoming))
        if self.camera is not None:
            ok, frame = self.camera.read()
            if ok:
                ns = time.monotonic_ns()
                self.last_camera_ns = ns
                events.append(Event(CAMERA, ns, encode_camera(frame)))
        return sorted(events, key=lambda e: e.host_ns)

    def close(self):
        if self.serial is not None:
            try:
                from .odom import build_odom_subscription
                self.serial.write(build_odom_subscription(continuous=False))
            finally:
                self.serial.close()
                self.serial = None
        if self.camera is not None:
            self.camera.release()
            self.camera = None
        if self.sock is not None:
            self.sock.close()
            self.sock = None


class ReplaySource:
    def __init__(self, directory: str | Path, speed: float = 1.0):
        if speed <= 0:
            raise ValueError("speed must be positive")
        self.reader = SessionReader(directory)
        self.iterator = iter(self.reader)
        self.speed = speed
        self.pending = next(self.iterator, None)
        self.first_ns = self.pending.host_ns if self.pending else 0
        self.start_ns = time.monotonic_ns()
        self.finished = self.pending is None

    def poll(self) -> list[Event]:
        now_elapsed = time.monotonic_ns()-self.start_ns
        result = []
        while self.pending and (self.pending.host_ns-self.first_ns)/self.speed <= now_elapsed:
            replay_ns = self.start_ns + int((self.pending.host_ns-self.first_ns)/self.speed)
            result.append(Event(self.pending.kind, replay_ns, self.pending.payload))
            self.pending = next(self.iterator, None)
        self.finished = self.pending is None
        return result

    def close(self):
        self.finished = True


def make_synthetic_odom(host_ns: int) -> bytes:
    payload = bytearray(51)
    payload[0] = 4
    struct.pack_into("<3h", payload, 7, 0, 0, 4000)
    struct.pack_into("<II", payload, 43, (host_ns//1_000_000) & 0xFFFFFFFF,
                     (host_ns//1000) % 1000)
    body = bytes((0xDF, 0x97, 0x01, 0x6C, 0x80, 51)) + bytes(payload) + b"\xfd"
    return body + struct.pack("<H", sum(body) & 0xFFFF)


class SyntheticSource:
    """Offline, repeatable 10 Hz LiDAR / 25 Hz camera / 10 Hz odometry."""

    def __init__(self, duration_s: float = 30.0, width: int = 640, height: int = 480):
        self.start_ns = time.monotonic_ns()
        self.duration_ns = int(duration_s*1e9)
        self.next_camera = self.next_lidar = self.next_odom = 0
        self.width, self.height = width, height
        self.finished = False

    @staticmethod
    def scan_points(frame_index: int) -> np.ndarray:
        pts = np.zeros(192, dtype=POINT_DTYPE)
        for k in range(96):
            pts[k]["x"] = 1800 + (k % 8)*25
            pts[k]["y"] = -500 + (k % 12)*25
            pts[k]["z"] = 200 + (k % 6)*40
            pts[96+k]["x"] = 3600 + (k % 8)*25
            pts[96+k]["y"] = 450 + (k % 12)*25
            pts[96+k]["z"] = 200 + (k % 6)*40
        return pts

    def poll(self) -> list[Event]:
        elapsed = min(time.monotonic_ns()-self.start_ns, self.duration_ns)
        events = []
        while self.next_lidar <= elapsed and self.next_lidar < self.duration_ns:
            tick = self.next_lidar
            points = self.scan_points(tick//100_000_000)
            for sub in range(2):
                raw = encode_mid360_for_test(points[sub*96:(sub+1)*96],
                                             tick+sub*480_000, 2*(tick//100_000_000)+sub)
                events.append(Event(RADAR, self.start_ns+tick+sub*480_000, raw))
            self.next_lidar += 100_000_000
        while self.next_odom <= elapsed and self.next_odom < self.duration_ns:
            tick = self.next_odom
            events.append(Event(ODOM, self.start_ns+tick,
                                make_synthetic_odom(self.start_ns+tick)))
            self.next_odom += 100_000_000
        while self.next_camera <= elapsed and self.next_camera < self.duration_ns:
            tick = self.next_camera
            frame = np.full((self.height, self.width, 3), (45, 45, 45), dtype=np.uint8)
            frame[self.height//3:self.height//2, self.width//3:self.width//2] = (70, 130, 210)
            events.append(Event(CAMERA, self.start_ns+tick, encode_camera(frame)))
            self.next_camera += 40_000_000
        self.finished = elapsed >= self.duration_ns
        return sorted(events, key=lambda e: e.host_ns)

    def close(self):
        self.finished = True
