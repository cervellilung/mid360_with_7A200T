"""ACX750 下行配置客户端（树莓派 → PL）。

用途：把上位机的配置读写命令经 UDP 发给 PL 的控制面，把 word_index/value
翻译成 PL 侧 perception_regs 的 AXI 访问。

> 权威协议定义应为 PL 侧 `fpga_acx750_full/docs/control_plane_750.md`；撰写本文件时
> 该文档尚不存在，故按任务给定的口径实现，并在 host/README.md 中如实标注。
> 另：当前 PL 侧只实现了 M3TL type=1/6（type=5/7 在做），**type=7 配置回读属待实现**，
> 因此 `read_word()` 是否真能收到应答取决于 PL 侧是否已落地；本客户端已带超时保护，
> 收不到只会抛 `CfgTimeout`。

UDP 目的地址默认 `192.168.1.50:56300`（PL 侧有独立的 UDP 接收端口，无需 magic），
载荷（全小端）：

| 偏移 | 字段       | 说明                                                     |
|-----:|------------|----------------------------------------------------------|
|    0 | opcode u8  | 0x01 写单字，0x02 读单字，0x03 批量写，0x04 触发快照读   |
|    1 | count u8   | 仅 0x03 用（1..16），其余填 1                            |
|  2-3 | reserved   | 0                                                       |
|    4 | 若干组     | 每组 `word_index:u16`，仅 0x01/0x03 再跟 `value:u32`     |

`word_index` 是 32 位字地址（0x000..0x3FF），**AXI 字节地址 = word_index*4**。
例如 word_index 0x40 ↔ 字节地址 0x100（配置区首字）。

读单字（0x02）后要等 PL 回 M3TL `type=7`（word_index + value）作为应答，
本模块在同一 socket 上收包解出应答，带超时保护。
"""
from __future__ import annotations

import argparse
import socket
import sys
import time
from pathlib import Path

_HOST_DIR = Path(__file__).resolve().parent
if str(_HOST_DIR) not in sys.path:
    sys.path.insert(0, str(_HOST_DIR))

import m3tl  # noqa: E402

# -- 默认地址与端口 --------------------------------------------------------
DEFAULT_HOST = "192.168.1.50"
# PL 侧有独立的 UDP 接收端口：56301 收 MID-360 点云，56300 收树莓派下行配置；
# 上行遥测走 46000。下行配置无需 magic，直接从 opcode 开始。
DEFAULT_PORT = 56300

# -- opcode ----------------------------------------------------------------
OP_WRITE_WORD = 0x01
OP_READ_WORD = 0x02
OP_BATCH_WRITE = 0x03
OP_TRIGGER_SNAPSHOT = 0x04

MAX_BATCH = 16
MAX_WORD_INDEX = 0x3FF

# -- perception_regs 寄存器映射（word_index 口径，word_index*4 = AXI 字节地址）--
REG_ID = 0x000            # 只读，恒为 0x31524550（"PEP1" 小端）
REG_SEQ = 0x001           # 只读，快照序号
REG_STATUS = 0x002        # 只读 bit0=config_pending，bit1=snapshot_busy；
#                           写入 bit0=1 置 pending（提交 shadow → 生效）
REG_ID_VALUE = 0x31524550
REG_CONFIG_BASE = 0x040   # 配置区 64 字：0x040..0x07F ↔ 字节 0x100..0x1FF
REG_CONFIG_COUNT = 64
REG_LUT_BASE = 0x100      # LUT 区 221 字：0x100..0x1DC ↔ 字节 0x400..0x773
REG_LUT_COUNT = 221
REG_SNAPSHOT_BASE = 0x200  # 快照只读 416 字：0x200..0x39F ↔ 字节 0x800..0xE7F
REG_SNAPSHOT_COUNT = 416


class CfgError(ValueError):
    """参数或协议错误。"""


class CfgTimeout(TimeoutError):
    """等待 PL type=7 应答超时。"""


# ---------------------------------------------------------------------------
# 载荷构造
# ---------------------------------------------------------------------------

def _pack_write_word(word_index: int, value: int) -> bytes:
    return build_command(OP_WRITE_WORD, 1, [(word_index, value)])


def _pack_read_word(word_index: int) -> bytes:
    return build_command(OP_READ_WORD, 1, [(word_index, None)])


def _pack_batch_write(pairs) -> bytes:
    return build_command(OP_BATCH_WRITE, len(pairs), [(i, v) for i, v in pairs])


def _pack_trigger_snapshot() -> bytes:
    return build_command(OP_TRIGGER_SNAPSHOT, 1, [])


def build_command(opcode: int, count: int, entries) -> bytes:
    """把一次命令打包为下行 UDP 载荷（见模块 docstring 的布局表）。

    载荷 = opcode(1) + count(1) + reserved(2) + 各组；word_index 从偏移 4 开始。
    """
    out = bytearray((int(opcode) & 0xFF, int(count) & 0xFF, 0, 0))
    for word_index, value in entries:
        if not 0 <= int(word_index) <= MAX_WORD_INDEX:
            raise CfgError(f"word_index 越界：{word_index}（合法 0x000..0x3FF）")
        out += int(word_index).to_bytes(2, "little")
        if opcode in (OP_WRITE_WORD, OP_BATCH_WRITE):
            if value is None:
                raise CfgError("写命令缺少 value")
            if not 0 <= int(value) <= 0xFFFFFFFF:
                raise CfgError(f"value 越界：{value}（合法 0..0xFFFFFFFF）")
            out += int(value).to_bytes(4, "little")
    return bytes(out)


def parse_reply(datagram: bytes) -> tuple[int, int] | None:
    """尝试把一条 UDP 载荷解成 M3TL type=7 应答，返回 (word_index, value)。

    非 type=7（或坏帧）返回 None，调用方可继续等其他包。
    """
    try:
        frame = m3tl.decode_frame(datagram)
    except m3tl.FrameError:
        return None
    if frame.type_id != int(m3tl.MessageType.CONFIG_READBACK):
        return None
    try:
        fields = m3tl.parse_payload(frame)
    except m3tl.FrameError:
        return None
    return int(fields["word_index"]), int(fields["value"])


# ---------------------------------------------------------------------------
# 客户端
# ---------------------------------------------------------------------------

class CfgClient:
    """下行配置客户端。线程不安全：一次只跑一个命令。"""

    def __init__(
        self,
        host: str = DEFAULT_HOST,
        port: int = DEFAULT_PORT,
        timeout: float = 1.0,
        bind: str | None = None,
    ) -> None:
        self.addr = (host, int(port))
        self.timeout = float(timeout)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.settimeout(self.timeout)
        if bind:
            self.sock.bind((bind, 0))

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass

    def __enter__(self) -> "CfgClient":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    # -- 底层 --------------------------------------------------------------

    def _send(self, payload: bytes) -> None:
        self.sock.sendto(payload, self.addr)

    # -- 命令 --------------------------------------------------------------

    def write_word(self, word_index: int, value: int) -> None:
        """写单个 32 位寄存器字。"""
        self._send(_pack_write_word(word_index, value))

    def read_word(self, word_index: int, timeout: float | None = None) -> int:
        """发起读单字并等待 PL 的 M3TL type=7 应答，返回 value。

        超时抛 CfgTimeout；收到其它类型（心跳等）会忽略并继续等。
        """
        self._send(_pack_read_word(word_index))
        deadline = time.monotonic() + (timeout if timeout is not None else self.timeout)
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise CfgTimeout(
                    f"读 word_index=0x{word_index:X} 等待 type=7 应答超时"
                )
            self.sock.settimeout(remaining)
            try:
                data, _addr = self.sock.recvfrom(65535)
            except socket.timeout:
                raise CfgTimeout(
                    f"读 word_index=0x{word_index:X} 等待 type=7 应答超时"
                ) from None
            reply = parse_reply(data)
            if reply is not None and reply[0] == int(word_index):
                return reply[1]
            # 其它包或不对应本请求的应答：继续等。

    def batch_write(self, pairs) -> None:
        """批量写 1..16 个寄存器字，pairs 为 (word_index, value) 序列。"""
        pairs = list(pairs)
        if not 1 <= len(pairs) <= MAX_BATCH:
            raise CfgError(f"批量写条数超限：{len(pairs)}（合法 1..{MAX_BATCH}）")
        self._send(_pack_batch_write(pairs))

    def trigger_snapshot(self) -> None:
        """触发一次快照读（快照内容经 type=7 或其它通道回读，视 PL 实现）。"""
        self._send(_pack_trigger_snapshot())


# ---------------------------------------------------------------------------
# 命令行入口
# ---------------------------------------------------------------------------

def _int(text: str) -> int:
    """支持 0x 前缀的整数解析。"""
    return int(text, 0)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="ACX750 下行配置客户端（UDP → PL 控制面）"
    )
    parser.add_argument("--host", default=DEFAULT_HOST, help=f"PL IP，默认 {DEFAULT_HOST}")
    parser.add_argument(
        "--port", type=int, default=DEFAULT_PORT,
        help=f"PL 下行配置 UDP 端口，默认 {DEFAULT_PORT}（可覆盖）",
    )
    parser.add_argument("--timeout", type=float, default=1.0, help="读应答超时（秒），默认 1.0")
    parser.add_argument(
        "--write", action="append", nargs=2, metavar=("IDX", "VALUE"),
        type=_int, help="写单字，可重复：--write 0x40 0xDEADBEEF",
    )
    parser.add_argument(
        "--read", action="append", nargs="+", metavar="IDX", type=_int,
        help="读单字（等 type=7 应答），可重复：--read 0x0 0x4",
    )
    parser.add_argument(
        "--batch", action="append", nargs="+", metavar="IDX=VALUE",
        help="批量写，可重复：--batch 0x40=1 0x41=2",
    )
    parser.add_argument("--snapshot", action="store_true", help="触发快照读")
    args = parser.parse_args(argv)

    actions = bool(args.write or args.read or args.batch or args.snapshot)
    if not actions:
        parser.error("未指定动作，至少给一个 --write/--read/--batch/--snapshot")

    client = CfgClient(host=args.host, port=args.port, timeout=args.timeout)
    rc = 0
    try:
        for idx, value in args.write or []:
            client.write_word(idx, value)
            print(f"写 word_index=0x{idx:03X}（字节 0x{idx * 4:03X}）<- 0x{value:08X}")
        for group in args.batch or []:
            pairs = []
            for item in group:
                if "=" not in item:
                    parser.error(f"--batch 项格式应为 IDX=VALUE，得到 {item!r}")
                left, right = item.split("=", 1)
                pairs.append((_int(left), _int(right)))
            client.batch_write(pairs)
            print(f"批量写 {len(pairs)} 个字：" + "，".join(
                f"0x{i:03X}=0x{v:08X}" for i, v in pairs
            ))
        for group in args.read or []:
            for idx in group:
                try:
                    value = client.read_word(idx)
                except CfgTimeout as error:
                    print(f"读 word_index=0x{idx:03X} 失败：{error}", file=sys.stderr)
                    rc = 2
                    continue
                print(f"读 word_index=0x{idx:03X}（字节 0x{idx * 4:03X}）-> 0x{value:08X}")
        if args.snapshot:
            client.trigger_snapshot()
            print("已发送触发快照请求")
    finally:
        client.close()
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
