"""离线回放：把 sessions/<name>/telemetry.jsonl 按时间戳节奏重发为 M3TL UDP 帧。

用途：现场无硬件时演示网页端（先起 server.py，再用本脚本灌数据）。
由于 JSONL 只保存解码后的字段，这里用 m3tl.encode_payload 重建载荷再打包。
"""
from __future__ import annotations

import argparse
import json
import socket
import sys
import time
from pathlib import Path

_HOST_DIR = Path(__file__).resolve().parent
if str(_HOST_DIR) not in sys.path:
    sys.path.insert(0, str(_HOST_DIR))

import m3tl  # noqa: E402


def iter_records(source: Path):
    """source 可以是 telemetry.jsonl 文件，也可以是包含它的目录。"""
    if source.is_dir():
        source = source / "telemetry.jsonl"
    with source.open("r", encoding="utf-8") as fp:
        for line in fp:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def main() -> int:
    parser = argparse.ArgumentParser(description="回放 M3TL telemetry.jsonl")
    parser.add_argument("source", type=Path, help="telemetry.jsonl 或其所在目录")
    parser.add_argument("--host", default="127.0.0.1", help="目标主机，默认本机")
    parser.add_argument("--port", type=int, default=46000, help="目标 UDP 端口")
    parser.add_argument("--speed", type=float, default=1.0, help="倍速，默认 1.0")
    parser.add_argument("--start", type=float, default=0.0, help="起点偏移（秒）")
    parser.add_argument("--duration", type=float, help="最长回放时长（秒）")
    parser.add_argument("--loop", action="store_true", help="循环回放")
    args = parser.parse_args()

    if args.speed <= 0 or args.start < 0:
        parser.error("speed 必须为正，start 不能为负")

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sent = 0
    skipped = 0
    try:
        while True:
            first_ms = None
            base = time.monotonic()
            for record in iter_records(args.source):
                type_id = record.get("type")
                if type_id is None or record.get("unknown"):
                    skipped += 1
                    continue
                try:
                    payload = m3tl.encode_payload(type_id, record)
                except m3tl.FrameError:
                    skipped += 1
                    continue
                t_ms = int(record.get("t_ms", 0))
                if first_ms is None:
                    first_ms = t_ms
                offset = (t_ms - first_ms) / 1000.0
                if offset < args.start:
                    continue
                if args.duration is not None and offset > args.start + args.duration:
                    break
                delay = (offset - args.start) / args.speed - (time.monotonic() - base)
                if delay > 0:
                    time.sleep(min(delay, 30))
                datagram = m3tl.encode_frame(
                    type_id,
                    payload,
                    int(record.get("seq", 0)),
                    t_ms,
                    int(record.get("flags", 0)),
                )
                sock.sendto(datagram, (args.host, args.port))
                sent += 1
            if not args.loop:
                break
    except KeyboardInterrupt:
        print("已中断")
    finally:
        sock.close()

    print(f"回放结束：发送 {sent} 帧，跳过 {skipped} 条（未知类型或不可编码）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())