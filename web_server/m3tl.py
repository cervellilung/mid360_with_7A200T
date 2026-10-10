"""M3TL v1 遥测帧协议：打包、解包、校验与载荷编解码。

本模块是 ACX750 新架构（XC7A200T 纯 FPGA，无 ARM PS）上位机的协议层。
与旧工程（AC880，Zynq 从 PS 用 TCP 拉 M3CP/M3PR 流）最大的区别是：
新架构由 PL 直接通过以太网 UDP 发送低带宽遥测结果，树莓派 5 只做接收。

帧结构（所有多字节整数均为小端）：

| 偏移 | 字段          | 类型     | 说明                                        |
|-----:|---------------|----------|---------------------------------------------|
|    0 | magic         | char[4]  | b"M3TL"                                     |
|    4 | version       | u8       | =1                                          |
|    5 | type          | u8       | 消息类型                                    |
|    6 | flags         | u16      | 保留                                        |
|    8 | payload_len   | u32      | 载荷长度，<=1024                            |
|   12 | sequence      | u32      | 每类消息独立递增                            |
|   16 | timestamp_ms  | u64      | PL 侧单调毫秒                               |
|   24 | header_crc32  | u32      | 对偏移 0..23 计算 CRC-32                    |
|   28 | payload_crc32 | u32      | 对载荷计算 CRC-32                           |

`header_crc32` / `payload_crc32` 与 Python `zlib.crc32` 一致。接收端要求
UDP 载荷长度严格等于 `32 + payload_len`，magic 正确，两个 CRC 均正确，
否则丢弃并计入坏包统计。

消息类型（权威口径见 `docs/telemetry_protocol.md` 末尾「类型补充」一节）：
    1 HEARTBEAT        16 字节
    2 CHASSIS          16 字节
    3 TARGETS          4 字节头 + count*16 字节
    5 GRID             8 字节头 + 413 字节位图（55x60 占据栅格）
    6 CAMERA_STATUS    12 字节
    7 CONFIG_READBACK  8 字节（PL 对下行读请求的应答）

`type=4` 在旧文档里曾写作「相机状态」，实际未采用，**保留不用**；相机状态用 type=6。

GRID 位序（务必严格照此，写错上位机画的栅格会横躺）：第 `r` 行第 `c` 列（均从 0 起）
对应字节下标 `(r*cols+c)//8` 的 `bit((r*cols+c)%8)`，即**每字节 bit0 先**。

未知 type 不报错：只按 payload_len 跳过并计一次 unknown。
"""
from __future__ import annotations

import base64
import enum
import struct
import zlib
from dataclasses import dataclass
from typing import Any, Iterable


# ---------------------------------------------------------------------------
# 常量与帧头
# ---------------------------------------------------------------------------

MAGIC = b"M3TL"
VERSION = 1
HEADER_SIZE = 32
MAX_PAYLOAD = 1024
MAX_FRAME = HEADER_SIZE + MAX_PAYLOAD

# <magic,version,type,flags,payload_len,sequence,timestamp_ms,header_crc,payload_crc>
HEADER = struct.Struct("<4sBBHIIQII")
assert HEADER.size == HEADER_SIZE, "帧头必须恰好 32 字节"


class MessageType(enum.IntEnum):
    """已知消息类型。未知类型在解析时按原始整数处理，不在此枚举内。"""

    HEARTBEAT = 1
    CHASSIS = 2
    TARGETS = 3
    GRID = 5
    CAMERA_STATUS = 6
    CONFIG_READBACK = 7
    ODOM_RAW = 8


KNOWN_TYPES = (1, 2, 3, 5, 6, 7, 8)


# ---------------------------------------------------------------------------
# 各类型载荷结构
# ---------------------------------------------------------------------------

# 心跳：pll_locked, ddr3_calib_done, eth_link_up, cam_init_done, stage, reserved[3],
#       uptime_ms, drop_count
HEARTBEAT = struct.Struct("<5B3xII")
# 底盘：yaw_q10000, body_vx_q5000, body_vy_q5000, chassis_ms
CHASSIS = struct.Struct("<iiiI")
# 目标：4 字节头
TARGETS_HEAD = struct.Struct("<BBH")
# 目标：单条 16 字节记录
TARGET = struct.Struct("<BBhhhhhhH")
# 栅格：rows, cols, cell_mm, reserved
GRID_HEAD = struct.Struct("<BBHI")
# 相机状态：frames, last_frame_ms, width, height
CAMERA_STATUS = struct.Struct("<IIHH")
# 配置回读：word_index, value（PL 对下行读请求的应答，随 M3TL 帧回来）
CONFIG_READBACK = struct.Struct("<II")

# 55x60 栅格常量
GRID_ROWS = 55
GRID_COLS = 60


class FrameError(ValueError):
    """帧解析失败。reason 用于坏包分类统计。"""

    def __init__(self, message: str, reason: str = "frame") -> None:
        super().__init__(message)
        self.reason = reason


@dataclass(frozen=True)
class Frame:
    """解包后的 M3TL 帧（载荷尚未解码）。"""

    type_id: int
    flags: int
    sequence: int
    timestamp_ms: int
    payload: bytes

    @property
    def type_name(self) -> str:
        try:
            return MessageType(self.type_id).name
        except ValueError:
            return "UNKNOWN"


# ---------------------------------------------------------------------------
# CRC 与帧打包 / 解包
# ---------------------------------------------------------------------------

def crc32(data: bytes) -> int:
    """与 zlib.crc32 一致的 CRC-32（无符号 32 位）。"""
    return zlib.crc32(data) & 0xFFFFFFFF


def encode_frame(
    type_id: int,
    payload: bytes,
    sequence: int,
    timestamp_ms: int,
    flags: int = 0,
) -> bytes:
    """按 M3TL v1 打包整帧。type_id 允许为未知类型。"""
    payload = bytes(payload)
    if len(payload) > MAX_PAYLOAD:
        raise FrameError(f"载荷过长：{len(payload)}", reason="payload")
    prefix = struct.pack(
        "<4sBBHIIQ",
        MAGIC,
        VERSION,
        int(type_id) & 0xFF,
        int(flags) & 0xFFFF,
        len(payload),
        int(sequence) & 0xFFFFFFFF,
        int(timestamp_ms) & 0xFFFFFFFFFFFFFFFF,
    )
    return prefix + struct.pack("<II", crc32(prefix), crc32(payload)) + payload


def decode_frame(datagram: bytes) -> Frame:
    """校验并解包一帧。任何不通过都抛 FrameError（带 reason）。"""
    if len(datagram) < HEADER_SIZE:
        raise FrameError("帧头不足 32 字节", reason="length")
    (
        magic,
        version,
        type_id,
        flags,
        payload_len,
        sequence,
        timestamp_ms,
        header_crc,
        payload_crc,
    ) = HEADER.unpack_from(datagram)
    if magic != MAGIC:
        raise FrameError(f"magic 错误：{magic!r}", reason="magic")
    if version != VERSION:
        raise FrameError(f"版本不支持：{version}", reason="version")
    if payload_len > MAX_PAYLOAD:
        raise FrameError(f"payload_len 超限：{payload_len}", reason="payload")
    expected = HEADER_SIZE + payload_len
    # 严格长度检查：UDP 载荷必须恰好等于 32 + payload_len。
    if len(datagram) != expected:
        raise FrameError(
            f"长度不匹配：收到 {len(datagram)}，应为 {expected}", reason="length"
        )
    if crc32(datagram[:24]) != header_crc:
        raise FrameError("帧头 CRC 不匹配", reason="header_crc")
    payload = datagram[HEADER_SIZE:]
    if crc32(payload) != payload_crc:
        raise FrameError("载荷 CRC 不匹配", reason="payload_crc")
    return Frame(type_id, flags, sequence, timestamp_ms, payload)


# ---------------------------------------------------------------------------
# 载荷解码
# ---------------------------------------------------------------------------

def _decode_heartbeat(payload: bytes) -> dict[str, Any]:
    if len(payload) != HEARTBEAT.size:
        raise FrameError(f"心跳载荷长度错误：{len(payload)}", reason="payload")
    (
        pll_locked,
        ddr3_calib_done,
        eth_link_up,
        cam_init_done,
        stage,
        uptime_ms,
        drop_count,
    ) = HEARTBEAT.unpack(payload)
    return {
        "pll_locked": bool(pll_locked),
        "ddr3_calib_done": bool(ddr3_calib_done),
        "eth_link_up": bool(eth_link_up),
        "cam_init_done": bool(cam_init_done),
        "stage": stage,
        "uptime_ms": uptime_ms,
        "drop_count": drop_count,
    }


def _decode_chassis(payload: bytes) -> dict[str, Any]:
    if len(payload) != CHASSIS.size:
        raise FrameError(f"底盘载荷长度错误：{len(payload)}", reason="payload")
    yaw, vx, vy, chassis_ms = CHASSIS.unpack(payload)
    return {
        "yaw_q10000": yaw,
        "body_vx_q5000": vx,
        "body_vy_q5000": vy,
        "chassis_ms": chassis_ms,
    }


def _decode_targets(payload: bytes) -> dict[str, Any]:
    if len(payload) < TARGETS_HEAD.size:
        raise FrameError("目标载荷头部不足", reason="payload")
    count, overflow, _reserved = TARGETS_HEAD.unpack_from(payload)
    expected = TARGETS_HEAD.size + count * TARGET.size
    if len(payload) != expected:
        raise FrameError(
            f"目标载荷长度错误：收到 {len(payload)}，应为 {expected}", reason="payload"
        )
    targets = []
    for index in range(count):
        values = TARGET.unpack_from(payload, TARGETS_HEAD.size + index * TARGET.size)
        targets.append(
            dict(
                zip(
                    (
                        "id",
                        "flags",
                        "x_min",
                        "x_max",
                        "y_min",
                        "y_max",
                        "z_min",
                        "z_max",
                        "nearest_mm",
                    ),
                    values,
                )
            )
        )
    return {"count": count, "overflow": bool(overflow), "targets": targets}


def _decode_grid(payload: bytes) -> dict[str, Any]:
    if len(payload) < GRID_HEAD.size:
        raise FrameError("栅格载荷头部不足", reason="payload")
    rows, cols, cell_mm, _reserved = GRID_HEAD.unpack_from(payload)
    bitmap_size = grid_bitmap_size(rows, cols)
    bitmap = payload[GRID_HEAD.size :]
    if len(bitmap) != bitmap_size:
        raise FrameError(
            f"栅格位图长度错误：收到 {len(bitmap)}，应为 {bitmap_size}", reason="payload"
        )
    return {
        "rows": rows,
        "cols": cols,
        "cell_mm": cell_mm,
        "occupied": sum(bin(byte).count("1") for byte in bitmap),
        "bitmap_hex": bitmap.hex(),
    }


def _decode_camera_status(payload: bytes) -> dict[str, Any]:
    if len(payload) != CAMERA_STATUS.size:
        raise FrameError(f"相机状态载荷长度错误：{len(payload)}", reason="payload")
    frames, last_frame_ms, width, height = CAMERA_STATUS.unpack(payload)
    return {
        "frames": frames,
        "last_frame_ms": last_frame_ms,
        "width": width,
        "height": height,
    }


def _decode_config_readback(payload: bytes) -> dict[str, Any]:
    if len(payload) != CONFIG_READBACK.size:
        raise FrameError(f"配置回读载荷长度错误：{len(payload)}", reason="payload")
    word_index, value = CONFIG_READBACK.unpack(payload)
    return {"word_index": word_index, "value": value}


def _decode_odom_raw(payload: bytes) -> dict[str, Any]:
    from web_server.pc_perception.odom import decode_odom_frame
    try:
        odom = decode_odom_frame(payload)
    except ValueError as error:
        raise FrameError(str(error), reason='payload') from error
    return dict(frame_hex=payload.hex(), attitude_q10000=list(odom.attitude_raw),
                position_raw=list(odom.position_raw), body_velocity_raw=list(odom.body_velocity_raw),
                time_ms=odom.time_ms, time_us=odom.time_us)


def _encode_odom_raw(fields):
    payload = bytes.fromhex(fields['frame_hex'])
    _decode_odom_raw(payload)
    return payload


_DECODERS = {
    MessageType.HEARTBEAT: _decode_heartbeat,
    MessageType.CHASSIS: _decode_chassis,
    MessageType.TARGETS: _decode_targets,
    MessageType.GRID: _decode_grid,
    MessageType.CAMERA_STATUS: _decode_camera_status,
    MessageType.CONFIG_READBACK: _decode_config_readback,
    MessageType.ODOM_RAW: _decode_odom_raw,
}


def parse_payload(frame: Frame) -> dict[str, Any]:
    """按 type 解码载荷。未知 type 返回 {"unknown": True, ...}，不报错。"""
    decoder = _DECODERS.get(frame.type_id)
    if decoder is None:
        return {
            "unknown": True,
            "type_id": frame.type_id,
            "payload_len": len(frame.payload),
        }
    return decoder(frame.payload)


def decode_message(datagram: bytes) -> tuple[Frame, dict[str, Any]]:
    """一次完成校验、解包与载荷解码，返回 (帧, 字段)。"""
    frame = decode_frame(datagram)
    return frame, parse_payload(frame)


# ---------------------------------------------------------------------------
# 载荷编码（回放与测试用）
# ---------------------------------------------------------------------------

def _encode_heartbeat(fields: dict[str, Any]) -> bytes:
    return HEARTBEAT.pack(
        int(bool(fields.get("pll_locked"))),
        int(bool(fields.get("ddr3_calib_done"))),
        int(bool(fields.get("eth_link_up"))),
        int(bool(fields.get("cam_init_done"))),
        int(fields.get("stage", 0)) & 0xFF,
        int(fields.get("uptime_ms", 0)) & 0xFFFFFFFF,
        int(fields.get("drop_count", 0)) & 0xFFFFFFFF,
    )


def _encode_chassis(fields: dict[str, Any]) -> bytes:
    return CHASSIS.pack(
        int(fields.get("yaw_q10000", 0)),
        int(fields.get("body_vx_q5000", 0)),
        int(fields.get("body_vy_q5000", 0)),
        int(fields.get("chassis_ms", 0)) & 0xFFFFFFFF,
    )


def _encode_targets(fields: dict[str, Any]) -> bytes:
    targets = fields.get("targets", []) or []
    count = int(fields.get("count", len(targets))) & 0xFF
    if len(targets) != count:
        raise FrameError(
            f"目标数量与列表不符：count={count}，列表={len(targets)}", reason="payload"
        )
    out = bytearray(TARGETS_HEAD.pack(count, int(bool(fields.get("overflow"))), 0))
    for target in targets:
        out += TARGET.pack(
            int(target.get("id", 0)) & 0xFF,
            int(target.get("flags", 0)) & 0xFF,
            int(target.get("x_min", 0)),
            int(target.get("x_max", 0)),
            int(target.get("y_min", 0)),
            int(target.get("y_max", 0)),
            int(target.get("z_min", 0)),
            int(target.get("z_max", 0)),
            int(target.get("nearest_mm", 0)) & 0xFFFF,
        )
    return bytes(out)


def _encode_grid(fields: dict[str, Any]) -> bytes:
    rows = int(fields.get("rows", GRID_ROWS)) & 0xFF
    cols = int(fields.get("cols", GRID_COLS)) & 0xFF
    cell_mm = int(fields.get("cell_mm", 0)) & 0xFFFF
    bitmap = fields.get("bitmap")
    if bitmap is None:
        # 支持三种来源：原字节、bitmap_hex（实时解码字段）、bitmap_b64（落盘瘦身字段）。
        hex_text = fields.get("bitmap_hex", "") or ""
        b64_text = fields.get("bitmap_b64", "") or ""
        if hex_text:
            bitmap = bytes.fromhex(hex_text)
        elif b64_text:
            bitmap = base64.b64decode(b64_text)
        else:
            bitmap = bytes(rows * cols + 7 >> 3)
    bitmap = bytes(bitmap)
    expected = grid_bitmap_size(rows, cols)
    if len(bitmap) != expected:
        raise FrameError(
            f"栅格位图长度错误：{len(bitmap)}，应为 {expected}", reason="payload"
        )
    return GRID_HEAD.pack(rows, cols, cell_mm, 0) + bitmap


def _encode_camera_status(fields: dict[str, Any]) -> bytes:
    return CAMERA_STATUS.pack(
        int(fields.get("frames", 0)) & 0xFFFFFFFF,
        int(fields.get("last_frame_ms", 0)) & 0xFFFFFFFF,
        int(fields.get("width", 0)) & 0xFFFF,
        int(fields.get("height", 0)) & 0xFFFF,
    )


def _encode_config_readback(fields: dict[str, Any]) -> bytes:
    return CONFIG_READBACK.pack(
        int(fields.get("word_index", 0)) & 0xFFFFFFFF,
        int(fields.get("value", 0)) & 0xFFFFFFFF,
    )


_ENCODERS = {
    MessageType.HEARTBEAT: _encode_heartbeat,
    MessageType.CHASSIS: _encode_chassis,
    MessageType.TARGETS: _encode_targets,
    MessageType.GRID: _encode_grid,
    MessageType.CAMERA_STATUS: _encode_camera_status,
    MessageType.CONFIG_READBACK: _encode_config_readback,
    MessageType.ODOM_RAW: _encode_odom_raw,
}


def encode_payload(type_id: int, fields: dict[str, Any]) -> bytes:
    """把已解码字段（或同结构 dict）重新编码为载荷字节，用于回放与往返测试。"""
    encoder = _ENCODERS.get(type_id)
    if encoder is None:
        raise FrameError(f"无法编码未知类型：{type_id}", reason="unknown")
    return encoder(fields)


# ---------------------------------------------------------------------------
# 55x60 占据栅格位图：行优先，每个格子最低位优先
# ---------------------------------------------------------------------------

def grid_bitmap_size(rows: int, cols: int) -> int:
    """位图字节数 = ceil(rows*cols/8)。55x60 -> 413。"""
    return (rows * cols + 7) // 8


def grid_index(row: int, col: int, cols: int) -> int:
    """格子 (row, col) 在位图中的线性下标。"""
    return row * cols + col


def grid_cell_bit(row: int, col: int, cols: int) -> tuple[int, int]:
    """格子 (row, col) 对应的 (字节下标, 位下标)。位下标 0 表示该字节 bit0。"""
    index = grid_index(row, col, cols)
    return index >> 3, index & 7


def pack_bitmap(bits: Iterable[int]) -> bytes:
    """把行优先的 0/1 序列打包为位图。第 i 个格子 -> byte[i//8] 的 bit(i%8)。"""
    values = list(bits)
    out = bytearray((len(values) + 7) // 8)
    for index, value in enumerate(values):
        if value:
            out[index >> 3] |= 1 << (index & 7)
    return bytes(out)


def unpack_bitmap(bitmap: bytes, rows: int, cols: int) -> list[int]:
    """把位图还原为行优先的 0/1 列表。"""
    total = rows * cols
    if len(bitmap) < (total + 7) // 8:
        raise FrameError("位图长度不足", reason="payload")
    return [(bitmap[index >> 3] >> (index & 7)) & 1 for index in range(total)]


def bitmap_from_hex(hex_text: str) -> bytes:
    """把解码字段里的 bitmap_hex 还原成字节。"""
    return bytes.fromhex(hex_text or "")
