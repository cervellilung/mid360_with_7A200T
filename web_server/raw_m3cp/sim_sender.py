"""Synthetic transport/load check. Every packet carries FLAG_SYNTHETIC."""
from __future__ import annotations

import argparse
import socket
import struct
import threading
import time
import zlib
from .wire import (CAMERA, CAMERA_META, CAMERA_YUYV, CHASSIS, FLAG_SYNTHETIC,
                   PORTS, RADAR, Record, encode)


def radar_payload(sequence: int) -> bytes:
    packet = bytearray(50)
    struct.pack_into("<BHHHHBBB", packet, 0, 0, 50, 4800, 1,
                     sequence & 0xFFFF, 0, 1, 0)
    struct.pack_into("<QiiiBB", packet, 28, sequence * 480_000,
                     1200, -350, 270, 64, 0)
    struct.pack_into("<I", packet, 24, zlib.crc32(packet[28:]) & 0xFFFFFFFF)
    return bytes(packet)


def chassis_payload(sequence: int) -> bytes:
    body = bytearray(60)
    body[0], body[3], body[4], body[5], body[6], body[57] = 0xDF, 0x6C, 0x80, 51, 4, 0xFD
    struct.pack_into("<I", body, 49, sequence * 100)
    struct.pack_into("<H", body, 58, sum(body[:-2]) & 0xFFFF)
    return bytes(body)


def send(kind: int, host: str, duration: float, boot_id: int, fps: int):
    rate = {RADAR: 2000, CAMERA: fps, CHASSIS: 100}[kind]
    camera_image = bytes((80, 128, 80, 128)) * (640 * 480 // 2)
    sequence = 0
    with socket.create_connection((host, PORTS[kind]), timeout=5) as conn:
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        deadline = time.monotonic() + duration
        next_tick = time.monotonic()
        while time.monotonic() < deadline:
            now = time.monotonic()
            if now < next_tick:
                time.sleep(min(next_tick - now, 0.01))
                continue
            capture_us = time.monotonic_ns() // 1000
            if kind == RADAR:
                payload = radar_payload(sequence)
            elif kind == CAMERA:
                payload = CAMERA_META.pack(640, 480, CAMERA_YUYV, 1280, sequence) + camera_image
            else:
                payload = chassis_payload(sequence)
            conn.sendall(encode(Record(kind, FLAG_SYNTHETIC, sequence, boot_id,
                                       capture_us, 0, payload)))
            sequence += 1
            next_tick += 1 / rate
    print(f"synthetic kind={kind} sent={sequence}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--duration", type=float, default=5)
    parser.add_argument("--fps", type=int, default=30)
    args = parser.parse_args()
    if args.duration <= 0 or args.fps <= 0:
        parser.error("duration and fps must be positive")
    boot_id = int(time.time_ns()) & 0xFFFFFFFFFFFFFFFF
    threads = [threading.Thread(target=send, args=(kind, args.host, args.duration,
                                                   boot_id, args.fps)) for kind in PORTS]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()


if __name__ == "__main__":
    main()
