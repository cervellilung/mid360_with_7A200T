"""会话落盘：把收到的 M3TL 消息写成 JSONL，并汇总 summary.json。

目录结构：
    sessions/<name>/telemetry.jsonl   每行一个 JSON 对象
    sessions/<name>/summary.json      本进程运行期间的统计汇总

telemetry.jsonl 每行字段：
    type   消息类型 id
    seq    该类型序号
    t_ms   PL 侧单调毫秒时间戳
    ...    解码后的字段（心跳/底盘/目标/栅格/相机状态/配置回读）

GRID（type=5）落盘瘦身：413 字节位图不逐字节（或不逐位）塞进 JSONL，而是落
`occupied_count`（占据格数）+ 可选的 `bitmap_b64`（413 字节位图的 base64，单串）。
选 base64 而非独立二进制侧文件的原因：JSONL 自包含、可直接用 replay.py 回放；
独立侧文件需要额外的偏移表与对齐逻辑，风险更高。需要更省空间时可用
`grid_bitmap=false` 关掉，只保留 occupied_count（此时 replay 无法重建栅格，会跳过）。
"""
from __future__ import annotations

import base64
import json
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def _iso(moment: float) -> str:
    return datetime.fromtimestamp(moment, tz=timezone.utc).astimezone().isoformat()


class Recorder:
    """线程安全的会话记录器。写入失败只标记状态，不抛出中断接收线程。"""

    def __init__(self, session_dir: str | Path, grid_bitmap: bool = True) -> None:
        self.root = Path(session_dir)
        self.grid_bitmap = bool(grid_bitmap)
        self.root.mkdir(parents=True, exist_ok=True)
        self.jsonl_path = self.root / "telemetry.jsonl"
        self.summary_path = self.root / "summary.json"
        self.existed = self.jsonl_path.exists()
        # 追加模式：重启同一会话不覆盖历史数据。
        self.fp = self.jsonl_path.open("a", encoding="utf-8")
        self.lock = threading.Lock()
        self.started_at = time.time()
        self.status = "recording"
        self.total_packets = 0
        self.unknown_packets = 0
        self.bytes_written = 0
        self.types: dict[str, dict[str, Any]] = {}
        self.rejected = {"magic": 0, "version": 0, "length": 0, "other": 0}
        self._last_flush = time.monotonic()

    # -- 内部 --------------------------------------------------------------

    def _bucket(self, type_id: int) -> dict[str, Any]:
        key = str(int(type_id))
        if key not in self.types:
            self.types[key] = {
                "packets": 0,
                "bad_crc": 0,
                "missing": 0,
                "first_t_ms": None,
                "last_t_ms": None,
                "last_seq": None,
            }
        return self.types[key]

    # -- 写入 --------------------------------------------------------------

    def _slim_fields(self, type_id: int, fields: dict[str, Any]) -> dict[str, Any]:
        """GRID 位图落盘瘦身：bitmap_hex -> occupied_count(+bitmap_b64)。"""
        if int(type_id) != 5:
            return fields
        out = {k: v for k, v in fields.items() if k != "bitmap_hex"}
        out["occupied_count"] = fields.get("occupied")
        hex_text = fields.get("bitmap_hex")
        if self.grid_bitmap and hex_text:
            out["bitmap_b64"] = base64.b64encode(bytes.fromhex(hex_text)).decode("ascii")
        return out

    def write(
        self, type_id: int, sequence: int, timestamp_ms: int, fields: dict[str, Any]
    ) -> None:
        """落盘一条已解码消息，并更新统计。"""
        record = {"type": int(type_id), "seq": int(sequence), "t_ms": int(timestamp_ms)}
        record.update(self._slim_fields(type_id, fields))
        line = json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n"
        with self.lock:
            if self.status != "recording":
                return
            try:
                self.fp.write(line)
            except OSError:
                self.status = "disk_write_error"
                return
            self.bytes_written += len(line.encode("utf-8"))
            self.total_packets += 1
            bucket = self._bucket(type_id)
            bucket["packets"] += 1
            if bucket["first_t_ms"] is None:
                bucket["first_t_ms"] = int(timestamp_ms)
            bucket["last_t_ms"] = int(timestamp_ms)
            last = bucket["last_seq"]
            if last is not None:
                delta = (int(sequence) - last) & 0xFFFFFFFF
                if 0 < delta < 0x80000000:
                    bucket["missing"] += delta - 1
            bucket["last_seq"] = int(sequence)
            now = time.monotonic()
            if now - self._last_flush >= 1.0:
                self._last_flush = now
                try:
                    self.fp.flush()
                except OSError:
                    self.status = "disk_write_error"

    def note_bad(self, type_id: int | None, reason: str) -> None:
        """记录一个坏包。CRC 错误按类型归入 bad_crc，其余归入 rejected 汇总。"""
        with self.lock:
            if "crc" in reason:
                if type_id is not None:
                    self._bucket(type_id)["bad_crc"] += 1
                else:
                    self.rejected["other"] += 1
                return
            self.rejected[reason if reason in self.rejected else "other"] += 1

    def note_unknown(self) -> None:
        with self.lock:
            self.unknown_packets += 1

    # -- 收尾 --------------------------------------------------------------

    def close(self) -> None:
        with self.lock:
            if self.status == "recording":
                self.status = "closed"
            try:
                self.fp.flush()
                self.fp.close()
            except OSError:
                self.status = "disk_write_error"
            self._write_summary()

    def _write_summary(self) -> None:
        first = None
        last = None
        for bucket in self.types.values():
            if bucket["first_t_ms"] is not None:
                first = bucket["first_t_ms"] if first is None else min(first, bucket["first_t_ms"])
                last = bucket["last_t_ms"] if last is None else max(last, bucket["last_t_ms"])
        summary = {
            "session": self.root.name,
            "started_at": _iso(self.started_at),
            "ended_at": _iso(time.time()),
            "total_packets": self.total_packets,
            "unknown_packets": self.unknown_packets,
            "bytes_written": self.bytes_written,
            "first_t_ms": first,
            "last_t_ms": last,
            "duration_ms": (last - first) if (first is not None and last is not None) else 0,
            "types": self.types,
            "rejected": self.rejected,
            "status": self.status,
        }
        tmp = self.summary_path.with_suffix(".json.tmp")
        try:
            tmp.write_text(
                json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
            )
            tmp.replace(self.summary_path)
        except OSError:
            self.status = "disk_report_write_error"

    @property
    def status_text(self) -> str:
        return self.status