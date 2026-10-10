"""Record raw MID-360 UDP into the existing PCSESS1 format without meshing."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import socket
import time

from .pc_perception.session import Event, RADAR, SessionReader, SessionWriter


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--duration', type=float, default=30)
    p.add_argument('--startup-timeout', type=float, default=12)
    p.add_argument('--bind', default='0.0.0.0')
    p.add_argument('--port', type=int, default=56301)
    p.add_argument('--lidar-ip', default='192.168.1.20')
    p.add_argument('--scene', default='real scene; sensor pose unverified')
    a = p.parse_args()
    if not 0 < a.duration <= 3600 or not 0 < a.startup_timeout <= 120:
        p.error('duration/startup-timeout outside supported range')
    peers = Counter()
    first = last = None
    payload_bytes = 0
    interrupted = False
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8*1024*1024)
        s.bind((a.bind, a.port))
        s.settimeout(.2)
        started = time.monotonic()
        with SessionWriter(a.out, dict(source='direct MID360', lidar_ip=a.lidar_ip,
                scene=a.scene, duration_s=a.duration, algorithm_run=False,
                duration_origin='first matching UDP packet')) as writer:
            print(f'Waiting for {a.lidar_ip} on {a.bind}:{a.port}', flush=True)
            try:
                while True:
                    now = time.monotonic()
                    deadline = started+a.startup_timeout if first is None else first+a.duration
                    if now >= deadline:
                        break
                    s.settimeout(min(.2, deadline-now))
                    try:
                        data, peer = s.recvfrom(65535)
                    except socket.timeout:
                        continue
                    received = time.monotonic()
                    if peer[0] != a.lidar_ip or received >= deadline:
                        continue
                    if first is None:
                        first = received
                        print(f'First packet received; recording {a.duration:g}s', flush=True)
                    writer.write(Event(RADAR, time.monotonic_ns(), data))
                    peers[f'{peer[0]}:{peer[1]}'] += 1
                    payload_bytes += len(data)
                    last = received
            except KeyboardInterrupt:
                interrupted = True
    # Read the closed file back: format/order/count validation only, no reconstruction.
    records = sum(1 for _ in SessionReader(a.out))
    path = a.out/'events.bin'
    with path.open('rb') as f:
        digest = hashlib.file_digest(f, 'sha256').hexdigest()
    ok = records > 0 and not interrupted and first is not None and time.monotonic()-first >= a.duration
    report = dict(status='recorded' if ok else 'incomplete', packets=sum(peers.values()),
        reread_records=records, peers=dict(peers), payload_bytes=payload_bytes,
        bytes=path.stat().st_size, requested_duration_s=a.duration,
        first_to_last_packet_s=None if first is None else last-first,
        receive_wait_s=None if first is None else first-started,
        sha256=digest, algorithm_run=False, protocol_validation='pending',
        interrupted=interrupted)
    (a.out/'capture_report.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print(json.dumps(report,indent=2),flush=True)
    print(f'Saved: {a.out.resolve()}',flush=True)
    return 0 if ok else 2


if __name__ == '__main__':
    raise SystemExit(main())
