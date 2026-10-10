"""Receive and record three independent PS TCP streams on Windows or Linux."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import socket
import threading
import time
import traceback
from .wire import HEADER, PORTS, Record, FrameError, decode, decode_header


def read_exact(conn: socket.socket, size: int, stop: threading.Event) -> bytes | None:
    chunks = bytearray()
    while len(chunks) < size and not stop.is_set():
        try:
            block = conn.recv(min(65536, size - len(chunks)))
        except socket.timeout:
            continue
        if not block:
            if chunks:
                raise FrameError("truncated stream")
            return None
        chunks.extend(block)
    return bytes(chunks) if len(chunks) == size else None


def receive_one(conn: socket.socket, kind: int, stop: threading.Event) -> tuple[Record, bytes] | None:
    header = read_exact(conn, HEADER.size, stop)
    if header is None:
        return None
    _, _, _, _, _, _, length, _ = decode_header(header, kind)
    payload = read_exact(conn, length, stop)
    if payload is None:
        raise FrameError("truncated payload")
    wire = header + payload
    return decode(wire, kind), wire


class Recorder:
    def __init__(self, directory: str | Path, bind: str, duration: float):
        self.directory = Path(directory)
        self.bind = bind
        self.duration = duration
        self.stop = threading.Event()
        self.lock = threading.Lock()
        self.stats = {kind: {"good": 0, "bad": 0, "missing": 0, "reconnects": 0,
                             "bytes": 0, "synthetic": 0} for kind in PORTS}
        self.last: dict[int, tuple[int, int]] = {}
        self.boot_id: int | None = None
        self.started_ns = time.monotonic_ns()

    def _serve(self, kind: int, server: socket.socket) -> None:
        path = self.directory / f"stream_{kind}.bin"
        with path.open("wb", buffering=1024 * 1024) as out:
            while not self.stop.is_set():
                try:
                    conn, _ = server.accept()
                except socket.timeout:
                    continue
                except OSError:
                    if self.stop.is_set():
                        break
                    # A transient accept error must not end the thread: if this
                    # returns, the port stops being accepted and the sender sees
                    # its reconnect SYNs time out even though the listener is
                    # still open.
                    continue
                try:
                    self._serve_connection(kind, conn, out)
                except Exception:  # noqa: BLE001
                    # Any unexpected failure used to kill this thread silently,
                    # which looked exactly like "the board's TCP stalled".
                    with self.lock:
                        self.stats[kind]["bad"] += 1
                    print(f"stream {kind}: handler failed, connection dropped", flush=True)
                    traceback.print_exc()
                finally:
                    conn.close()

    def _serve_connection(self, kind: int, conn: socket.socket, out) -> None:
        """Read one connection until it ends; never raises for expected cases."""
        conn.settimeout(1.0)
        with self.lock:
            self.stats[kind]["reconnects"] += 1
        # Buffered frame reader: pull large blocks and slice records from the
        # buffer so per-record recv syscalls do not throttle the stream.
        buf = bytearray()
        pos = 0
        while not self.stop.is_set():
            # Parse every complete record currently buffered.
            try:
                while len(buf) - pos >= HEADER.size:
                    _, _, _, _, _, _, length, _ = decode_header(
                        bytes(buf[pos:pos + HEADER.size]), kind)
                    total = HEADER.size + length
                    if len(buf) - pos < total:
                        break
                    wire = bytes(buf[pos:pos + total])
                    pos += total
                    rec = decode(wire, kind)
                    with self.lock:
                        if self.boot_id is None:
                            self.boot_id = rec.boot_id
                        if rec.boot_id != self.boot_id:
                            self.stats[kind]["bad"] += 1
                            continue
                        previous = self.last.get(kind)
                        if previous is not None and previous[0] == rec.boot_id:
                            gap = (rec.sequence - previous[1]) & 0xFFFFFFFF
                            if gap == 0 or gap > 0x80000000:
                                self.stats[kind]["bad"] += 1
                                continue
                            self.stats[kind]["missing"] += gap - 1
                        self.last[kind] = (rec.boot_id, rec.sequence)
                        out.write(wire)
                        self.stats[kind]["good"] += 1
                        self.stats[kind]["bytes"] += len(wire)
                        if rec.flags & 1:
                            self.stats[kind]["synthetic"] += 1
                        if self.stats[kind]["good"] % 100 == 0:
                            out.flush()
            except FrameError as exc:
                with self.lock:
                    self.stats[kind]["bad"] += 1
                print(f"stream {kind}: {exc}", flush=True)
                break
            if pos > 131072:
                del buf[:pos]
                pos = 0
            try:
                block = conn.recv(262144)
            except socket.timeout:
                continue
            except OSError as exc:
                with self.lock:
                    self.stats[kind]["bad"] += 1
                print(f"stream {kind}: {exc}", flush=True)
                break
            if not block:
                if len(buf) != pos:
                    with self.lock:
                        self.stats[kind]["bad"] += 1
                    print(f"stream {kind}: truncated trailing record", flush=True)
                break
            buf += block

    def run(self) -> dict:
        if self.directory.exists():
            raise FileExistsError(self.directory)
        self.directory.mkdir(parents=True)
        servers = []
        threads = []
        try:
            for kind, port in PORTS.items():
                server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                server.bind((self.bind, port))
                server.listen(2)
                server.settimeout(0.5)
                servers.append(server)
                thread = threading.Thread(target=self._serve, args=(kind, server), daemon=True)
                threads.append(thread)
                thread.start()
            print(f"recording {self.bind} ports {list(PORTS.values())} for {self.duration}s", flush=True)
            self.stop.wait(self.duration)
        finally:
            self.stop.set()
            for server in servers:
                server.close()
            for thread in threads:
                thread.join(timeout=2)
            elapsed = (time.monotonic_ns() - self.started_ns) / 1e9
            report = {"format": "M3CP-v1", "boot_id": self.boot_id,
                      "duration_s": elapsed, "streams": self.stats,
                      "camera_fps": self.stats[2]["good"] / elapsed if elapsed else 0}
            (self.directory / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
        return report


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", required=True, help="PC/Pi wired-interface IPv4 address")
    parser.add_argument("--duration", type=float, default=60)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.duration <= 0:
        parser.error("duration must be positive")
    print(json.dumps(Recorder(args.output, args.bind, args.duration).run(), indent=2))


if __name__ == "__main__":
    main()
