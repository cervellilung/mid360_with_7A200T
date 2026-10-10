"""ACX750 上位机 UDP 接收服务 + 本地网页状态接口。

职责：
  * 从 PL 的以太网 UDP 直接接收 M3TL v1 遥测帧（默认绑定 0.0.0.0:46000）；
  * 按 type 分发，维护每类消息的最新状态与统计（含序号缺口、CRC 坏包）；
  * 指定 --session 时把每条消息落盘到 sessions/<name>/telemetry.jsonl；
  * 通过只读 HTTP 服务把状态喂给本地网页 viewer.html。

与旧工程（AC880 从 PS 用 TCP 拉流）最大的区别：这里是自己监听 UDP 收包。
接收线程必须捕获所有异常并打印 traceback，绝不允许静默退出。
"""
from __future__ import annotations

import argparse
import json
import logging
import socket
import sys
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# 允许直接 `python server.py` 运行，也允许作为包导入。
_HOST_DIR = Path(__file__).resolve().parent
if str(_HOST_DIR) not in sys.path:
    sys.path.insert(0, str(_HOST_DIR))

import m3tl  # noqa: E402
from recording import Recorder  # noqa: E402

LOG = logging.getLogger("mid360.host")

DEFAULT_BIND = "0.0.0.0"
DEFAULT_PORT = 46000
DEFAULT_WEB_BIND = "0.0.0.0"
DEFAULT_WEB_PORT = 8765
DEFAULT_SESSION_DIR = "sessions"


def _new_stat() -> dict:
    return {
        "good": 0,
        "bad_crc": 0,
        "bad_length": 0,
        "bad_magic": 0,
        "bad_version": 0,
        "unknown": 0,
        "missing": 0,
        "last_seq": None,
        "last_t_ms": None,
        "received_at": None,
    }


class Hub:
    """接收、统计与状态汇总。所有共享状态用 lock 保护。"""

    def __init__(self, config: dict, session: str | None = None, record: bool = True):
        self.config = config
        self.stop = threading.Event()
        self.lock = threading.Lock()
        self.recv_sock: socket.socket | None = None
        self.thread: threading.Thread | None = None
        self.started_at = time.monotonic()
        self.total_packets = 0
        self.bad_packets = 0
        self.unknown_packets = 0
        self.recv_errors = 0

        self.stats: dict[str, dict] = {str(t): _new_stat() for t in m3tl.KNOWN_TYPES}
        self.stats["unknown"] = _new_stat()
        self.latest: dict[str, dict] = {}

        session_dir = config.get("session_dir", DEFAULT_SESSION_DIR)
        self.session = session
        self.recorder = (
            Recorder(
                Path(session_dir) / session,
                grid_bitmap=bool(config.get("grid_bitmap", True)),
            )
            if (record and session)
            else None
        )

    # -- 统计辅助 ----------------------------------------------------------

    def _stat_for(self, type_id) -> dict:
        key = str(int(type_id))
        return self.stats.get(key, self.stats["unknown"])

    def _note_bad(self, type_id, reason: str) -> None:
        stat = self._stat_for(type_id) if type_id is not None else self.stats["unknown"]
        if reason in ("header_crc", "payload_crc"):
            stat["bad_crc"] += 1
        elif reason == "length":
            stat["bad_length"] += 1
        elif reason == "magic":
            stat["bad_magic"] += 1
        elif reason == "version":
            stat["bad_version"] += 1
        else:
            stat["bad_length"] += 1
        self.bad_packets += 1
        if self.recorder is not None:
            self.recorder.note_bad(type_id, reason)

    # -- 收包处理 ----------------------------------------------------------

    def handle(self, data: bytes, addr) -> None:
        now = time.monotonic()
        try:
            frame = m3tl.decode_frame(data)
        except m3tl.FrameError as error:
            # 长度/magic 已坏时仍可能读到 type 字节，用于归类统计。
            type_id = None
            if len(data) >= 6 and data[:4] == m3tl.MAGIC:
                type_id = data[5]
            with self.lock:
                self._note_bad(type_id, error.reason)
            return

        try:
            fields = m3tl.parse_payload(frame)
        except m3tl.FrameError as error:
            with self.lock:
                self._note_bad(frame.type_id, error.reason)
            return

        known = frame.type_id in m3tl.KNOWN_TYPES
        with self.lock:
            self.total_packets += 1
            if not known:
                self.unknown_packets += 1
                self.stats["unknown"]["unknown"] += 1
                self.stats["unknown"]["good"] += 1
                self.stats["unknown"]["received_at"] = now
                if self.recorder is not None:
                    self.recorder.note_unknown()
                return
            stat = self.stats[str(frame.type_id)]
            last_seq = stat["last_seq"]
            if last_seq is not None:
                delta = (frame.sequence - last_seq) & 0xFFFFFFFF
                if 0 < delta < 0x80000000:
                    stat["missing"] += delta - 1
            stat["good"] += 1
            stat["last_seq"] = frame.sequence
            stat["last_t_ms"] = frame.timestamp_ms
            stat["received_at"] = now
            entry = {
                "seq": frame.sequence,
                "t_ms": frame.timestamp_ms,
                "flags": frame.flags,
                "received_at": now,
            }
            entry.update(fields)
            self.latest[str(frame.type_id)] = entry
        if self.recorder is not None:
            self.recorder.write(
                frame.type_id, frame.sequence, frame.timestamp_ms, fields
            )

    # -- 接收线程 ----------------------------------------------------------

    def _receiver(self) -> None:
        sock = self.recv_sock
        assert sock is not None
        while not self.stop.is_set():
            try:
                data, addr = sock.recvfrom(65535)
            except socket.timeout:
                continue
            except OSError as error:
                if self.stop.is_set():
                    break
                self.recv_errors += 1
                LOG.error("UDP 接收错误：%s", error)
                traceback.print_exc()
                time.sleep(0.1)
                continue
            try:
                self.handle(data, addr)
            except Exception:  # noqa: BLE001 - 绝不允许接收线程静默退出
                LOG.error("处理数据包时出现未预期异常（来自 %s）", addr)
                traceback.print_exc()

    def start(self) -> None:
        bind = self.config.get("bind", DEFAULT_BIND)
        port = int(self.config.get("port", DEFAULT_PORT))
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
        except OSError:
            pass
        sock.bind((bind, port))
        sock.settimeout(0.5)
        self.recv_sock = sock
        self.thread = threading.Thread(
            target=self._receiver, name="udp-receiver", daemon=True
        )
        self.thread.start()
        LOG.info("UDP 接收已启动：%s:%d", bind, port)

    def close(self) -> None:
        self.stop.set()
        if self.recv_sock is not None:
            try:
                self.recv_sock.close()
            except OSError:
                pass
        if self.thread is not None:
            self.thread.join(2)
        if self.recorder is not None:
            self.recorder.close()

    # -- 状态输出 ----------------------------------------------------------

    def state(self) -> dict:
        now = time.monotonic()
        with self.lock:
            streams = {}
            for key, stat in self.stats.items():
                received_at = stat["received_at"]
                streams[key] = {
                    **stat,
                    "age_ms": (
                        round((now - received_at) * 1000)
                        if received_at is not None
                        else None
                    ),
                }
            latest = {}
            for key, entry in self.latest.items():
                item = dict(entry)
                item.pop("received_at", None)
                item["age_ms"] = round((now - entry["received_at"]) * 1000)
                latest[key] = item
            return {
                "uptime_ms": round((now - self.started_at) * 1000),
                "total_packets": self.total_packets,
                "bad_packets": self.bad_packets,
                "unknown_packets": self.unknown_packets,
                "recv_errors": self.recv_errors,
                "streams": streams,
                "latest": latest,
                "recording": (
                    self.recorder.status_text if self.recorder else "disabled"
                ),
                "session": self.session,
            }


# ---------------------------------------------------------------------------
# 只读 HTTP 服务（本地网页）
# ---------------------------------------------------------------------------

def make_http_server(hub: Hub, host: str, port: int) -> ThreadingHTTPServer:
    viewer_path = _HOST_DIR / "viewer.html"

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802
            path = self.path.split("?", 1)[0]
            if path == "/api/state":
                body = json.dumps(hub.state(), ensure_ascii=False).encode("utf-8")
                mime = "application/json; charset=utf-8"
            elif path in ("/", "/index.html", "/viewer.html"):
                try:
                    body = viewer_path.read_bytes()
                    mime = "text/html; charset=utf-8"
                except OSError:
                    self.send_error(500, "viewer.html missing")
                    return
            else:
                self.send_error(404, "not found")
                return
            self.send_response(200)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def log_message(self, *args) -> None:  # 静默访问日志
            return

    return ThreadingHTTPServer((host, port), Handler)


# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------

def load_config(path: str | None) -> dict:
    if not path:
        return {}
    text = Path(path).read_text(encoding="utf-8-sig")
    return json.loads(text)


def build_config(args) -> dict:
    config = load_config(args.config)
    if args.bind is not None:
        config["bind"] = args.bind
    if args.port is not None:
        config["port"] = args.port
    if args.web_bind is not None:
        config["web_bind"] = args.web_bind
    if args.web_port is not None:
        config["web_port"] = args.web_port
    if args.session_dir is not None:
        config["session_dir"] = args.session_dir
    config.setdefault("bind", DEFAULT_BIND)
    config.setdefault("port", DEFAULT_PORT)
    config.setdefault("web_bind", DEFAULT_WEB_BIND)
    config.setdefault("web_port", DEFAULT_WEB_PORT)
    config.setdefault("session_dir", DEFAULT_SESSION_DIR)
    config.setdefault("record", True)
    return config


def main() -> int:
    parser = argparse.ArgumentParser(description="ACX750 M3TL UDP 遥测接收上位机")
    parser.add_argument("--config", help="配置文件路径（JSON）")
    parser.add_argument("--bind", help="UDP 监听地址，默认 0.0.0.0")
    parser.add_argument("--port", type=int, help="UDP 监听端口，默认 46000")
    parser.add_argument("--web-bind", help="网页服务监听地址")
    parser.add_argument("--web-port", type=int, help="网页服务端口，默认 8765")
    parser.add_argument("--session", help="会话名，指定后把消息落盘到 sessions/<name>/")
    parser.add_argument("--session-dir", help="会话根目录，默认 sessions")
    parser.add_argument("--no-record", action="store_true", help="只接收不落盘")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s"
    )

    config = build_config(args)
    record = bool(config.get("record", True)) and not args.no_record
    session = args.session or config.get("session")

    hub = Hub(config, session=session, record=record)
    http = make_http_server(
        hub, config.get("web_bind", DEFAULT_WEB_BIND), int(config.get("web_port"))
    )
    try:
        hub.start()
        LOG.info(
            "网页状态接口已启动：http://%s:%d/　会话：%s　落盘：%s",
            config.get("web_bind"),
            http.server_port,
            session or "未指定",
            "开" if hub.recorder else "关",
        )
        http.serve_forever()
    except KeyboardInterrupt:
        LOG.info("收到中断，正在退出……")
    finally:
        http.shutdown()
        hub.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())