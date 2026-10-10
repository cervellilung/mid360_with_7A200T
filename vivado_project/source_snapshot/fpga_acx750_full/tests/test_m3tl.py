"""M3TL v1 协议自检。直接用标准库运行：python tests/test_m3tl.py

覆盖：CRC 与 zlib 一致、帧头布局、严格长度校验、坏包分类、
各类型（1/2/3/5/6/7）编解码往返与边界、GRID 位序已知测试向量（含两格向量）、
payload_len 与实际长度不符、未知类型容忍。
"""
from __future__ import annotations

import base64
import struct
import sys
import zlib
from pathlib import Path

# 把 host 目录加入模块搜索路径，允许从任意目录运行本脚本。
HOST_DIR = Path(__file__).resolve().parent.parent / "host"
sys.path.insert(0, str(HOST_DIR))

import m3tl  # noqa: E402

PASSED = 0
FAILED = 0


def check(name: str, condition: bool, detail: str = "") -> None:
    global PASSED, FAILED
    if condition:
        PASSED += 1
        print(f"  [OK] {name}")
    else:
        FAILED += 1
        print(f"  [FAIL] {name} {detail}")


def expect_error(name: str, datagram: bytes, reason: str) -> None:
    global PASSED, FAILED
    try:
        m3tl.decode_frame(datagram)
    except m3tl.FrameError as error:
        if error.reason == reason:
            PASSED += 1
            print(f"  [OK] {name}（reason={error.reason}）")
        else:
            FAILED += 1
            print(f"  [FAIL] {name} 期望 reason={reason}，实际 {error.reason}")
        return
    FAILED += 1
    print(f"  [FAIL] {name} 未抛出 FrameError")


def test_header_layout() -> None:
    print("== 帧头布局与 CRC ==")
    payload = m3tl.encode_payload(1, {"pll_locked": True, "uptime_ms": 1234})
    frame = m3tl.encode_frame(1, payload, sequence=7, timestamp_ms=987654321)
    check("帧长为 32+payload", len(frame) == m3tl.HEADER_SIZE + len(payload))
    magic, version, type_id, flags, plen, seq, ts = struct.unpack_from(
        "<4sBBHIIQ", frame, 0
    )
    check("偏移0 magic=M3TL", magic == b"M3TL")
    check("偏移4 version=1", version == 1)
    check("偏移5 type=1", type_id == 1)
    check("偏移6 flags=0", flags == 0)
    check("偏移8 payload_len 正确", plen == len(payload) == 16)
    check("偏移12 sequence=7", seq == 7)
    check("偏移16 timestamp_ms 正确", ts == 987654321)
    header_crc, payload_crc = struct.unpack_from("<II", frame, 24)
    check("偏移24 帧头 CRC == zlib.crc32(0..23)", header_crc == zlib.crc32(frame[:24]) & 0xFFFFFFFF)
    check("偏移28 载荷 CRC == zlib.crc32(载荷)", payload_crc == zlib.crc32(payload) & 0xFFFFFFFF)
    check("总长 1056 为最大帧", m3tl.MAX_FRAME == 1056)


def test_crc_reference() -> None:
    print("== CRC 与 zlib 参考一致 ==")
    sample = bytes(range(24))
    check("crc32 与 zlib 相同", m3tl.crc32(sample) == zlib.crc32(sample) & 0xFFFFFFFF)
    check("空载荷 CRC 为 0", m3tl.crc32(b"") == 0)


def test_bad_frames() -> None:
    print("== 坏包分类 ==")
    payload = m3tl.encode_payload(6, {"frames": 5, "last_frame_ms": 100, "width": 640, "height": 480})
    good = m3tl.encode_frame(6, payload, sequence=1, timestamp_ms=1)
    expect_error("长度过短", good[:-1], "length")
    expect_error("长度过长", good + b"\x00", "length")
    expect_error("不足 32 字节", good[:20], "length")

    bad_magic = bytearray(good)
    bad_magic[0:4] = b"XXXX"
    expect_error("magic 错误", bytes(bad_magic), "magic")

    bad_version = bytearray(good)
    bad_version[4] = 2
    expect_error("版本错误", bytes(bad_version), "version")

    bad_header_crc = bytearray(good)
    bad_header_crc[24] ^= 0xFF
    expect_error("帧头 CRC 错误", bytes(bad_header_crc), "header_crc")

    bad_payload_crc = bytearray(good)
    bad_payload_crc[28] ^= 0xFF
    expect_error("载荷 CRC 错误", bytes(bad_payload_crc), "payload_crc")

    # 载荷被篡改但没有更新 CRC -> 载荷 CRC 错误
    bad_body = bytearray(good)
    bad_body[-1] ^= 0x01
    expect_error("载荷被篡改", bytes(bad_body), "payload_crc")


def test_roundtrip() -> None:
    print("== 各类型编解码往返 ==")
    cases = [
        (1, {
            "pll_locked": True, "ddr3_calib_done": True, "eth_link_up": False,
            "cam_init_done": True, "stage": 3, "uptime_ms": 123456, "drop_count": 9,
        }),
        (2, {
            "yaw_q10000": -31415, "body_vx_q5000": -2500,
            "body_vy_q5000": 1234, "chassis_ms": 4294967295,
        }),
        (3, {
            "count": 2, "overflow": True,
            "targets": [
                {"id": 1, "flags": 1, "x_min": -100, "x_max": 200, "y_min": -50,
                 "y_max": 50, "z_min": 0, "z_max": 1800, "nearest_mm": 300},
                {"id": 7, "flags": 0, "x_min": 1000, "x_max": 1200, "y_min": -300,
                 "y_max": -100, "z_min": -100, "z_max": 900, "nearest_mm": 1100},
            ],
        }),
        (6, {"frames": 4294967295, "last_frame_ms": 5000, "width": 1920, "height": 1080}),
        (7, {"word_index": 0x040, "value": 0xDEADBEEF}),
    ]
    for type_id, fields in cases:
        payload = m3tl.encode_payload(type_id, fields)
        frame = m3tl.encode_frame(type_id, payload, sequence=99, timestamp_ms=777)
        decoded_frame, decoded = m3tl.decode_message(frame)
        check(
            f"type={type_id} 载荷长度往返一致",
            len(decoded_frame.payload) == len(payload),
        )
        check(f"type={type_id} 字段往返一致", decoded == fields, f"得到 {decoded}")

    # 目标数量与列表不符必须报错
    try:
        m3tl.encode_payload(3, {"count": 5, "targets": []})
        check("目标数量校验", False, "未报错")
    except m3tl.FrameError:
        check("目标数量校验", True)


def test_grid_bit_order() -> None:
    print("== GRID 位序已知测试向量 ==")
    # 已知小向量：2 行 3 列，点亮 (0,0)、(0,2)、(1,1)。
    # 线性下标 0、2、4 -> 同一字节 bit0、bit2、bit4 -> 0b00010101 = 0x15。
    cells = [0] * 6
    cells[m3tl.grid_index(0, 0, 3)] = 1
    cells[m3tl.grid_index(0, 2, 3)] = 1
    cells[m3tl.grid_index(1, 1, 3)] = 1
    bitmap = m3tl.pack_bitmap(cells)
    check("小向量字节数 = ceil(6/8) = 1", len(bitmap) == 1)
    check("小向量字节值 = 0x15", bitmap[0] == 0x15, f"得到 0x{bitmap[0]:02x}")
    check("小向量还原一致", m3tl.unpack_bitmap(bitmap, 2, 3) == cells)

    # 55x60 边界：只点亮 (54,59)，线性下标 3299 -> byte 412 的 bit3 = 0x08。
    total = m3tl.GRID_ROWS * m3tl.GRID_COLS
    check("55*60 = 3300", total == 3300)
    check("位图字节数 = 413", m3tl.grid_bitmap_size(55, 60) == 413)
    big = bytearray(413)
    index = m3tl.grid_index(54, 59, m3tl.GRID_COLS)
    check("(54,59) 线性下标 = 3299", index == 3299)
    big[index >> 3] |= 1 << (index & 7)
    check("末字节 = 0x08", big[412] == 0x08, f"得到 0x{big[412]:02x}")
    check("首字节 = 0x00", big[0] == 0x00)
    restored = m3tl.unpack_bitmap(bytes(big), 55, 60)
    check("还原后仅该格点亮", restored.count(1) == 1 and restored[index] == 1)

    # 通过 encode/decode 走一遍完整帧
    fields = {
        "rows": 55, "cols": 60, "cell_mm": 100,
        "bitmap_hex": bytes(big).hex(),
    }
    payload = m3tl.encode_payload(5, fields)
    check("GRID 载荷 = 8 + 413", len(payload) == 421)
    frame = m3tl.encode_frame(5, payload, sequence=1, timestamp_ms=1)
    _, decoded = m3tl.decode_message(frame)
    check("GRID occupied = 1", decoded["occupied"] == 1)
    check("GRID bitmap 往返一致", decoded["bitmap_hex"] == bytes(big).hex())
    check("GRID cell_mm = 100", decoded["cell_mm"] == 100)

    # 错误位图长度必须报错
    try:
        m3tl.encode_payload(5, {"rows": 55, "cols": 60, "cell_mm": 100, "bitmap": bytes(10)})
        check("GRID 位图长度校验", False, "未报错")
    except m3tl.FrameError:
        check("GRID 位图长度校验", True)


def test_grid_two_cell_vector() -> None:
    """指定的两格测试向量：只置 (r=3,c=7) 与 (r=10,c=2)，断言解出来正好是这两格。

    位序规则：线性下标 = r*60+c；字节 = 下标//8，位 = 下标%8（bit0 先）。
    (3,7) -> 187 -> 字节 23 的 bit3 -> 0x08
    (10,2) -> 602 -> 字节 75 的 bit2 -> 0x04
    """
    print("== GRID 两格测试向量 (3,7) & (10,2) ==")
    rows, cols = 55, 60
    check("(3,7) -> (字节23, 位3)", m3tl.grid_cell_bit(3, 7, cols) == (23, 3))
    check("(10,2) -> (字节75, 位2)", m3tl.grid_cell_bit(10, 2, cols) == (75, 2))

    bitmap = bytearray(m3tl.grid_bitmap_size(rows, cols))
    for row, col in ((3, 7), (10, 2)):
        byte_i, bit_i = m3tl.grid_cell_bit(row, col, cols)
        bitmap[byte_i] |= 1 << bit_i
    check("字节23 = 0x08", bitmap[23] == 0x08, f"得到 0x{bitmap[23]:02x}")
    check("字节75 = 0x04", bitmap[75] == 0x04, f"得到 0x{bitmap[75]:02x}")
    check("其余字节全 0", sum(bitmap) == 0x0C)

    restored = m3tl.unpack_bitmap(bytes(bitmap), rows, cols)
    idx_a = m3tl.grid_index(3, 7, cols)
    idx_b = m3tl.grid_index(10, 2, cols)
    check("还原后恰好 2 格点亮", restored.count(1) == 2)
    check("(3,7) 点亮", restored[idx_a] == 1)
    check("(10,2) 点亮", restored[idx_b] == 1)
    # 反证防横躺：若行列被写反，(7,3)/(2,10) 不应被点亮。
    check("(7,3) 未点亮（防横躺）", restored[m3tl.grid_index(7, 3, cols)] == 0)
    check("(2,10) 未点亮（防横躺）", restored[m3tl.grid_index(2, 10, cols)] == 0)

    # 走一遍 bitmap_b64 编码路径（落盘瘦身字段的回放路径）。
    fields = {
        "rows": rows, "cols": cols, "cell_mm": 100,
        "bitmap_b64": base64.b64encode(bytes(bitmap)).decode("ascii"),
    }
    payload = m3tl.encode_payload(5, fields)
    check("bitmap_b64 载荷 = 8 + 413", len(payload) == 421)
    _, decoded = m3tl.decode_message(
        m3tl.encode_frame(5, payload, sequence=1, timestamp_ms=1)
    )
    check("bitmap_b64 回放 occupied = 2", decoded["occupied"] == 2)
    check("bitmap_b64 回放位图一致", decoded["bitmap_hex"] == bytes(bitmap).hex())

    # bitmap_b64 长度不对也要报错。
    try:
        m3tl.encode_payload(5, {"rows": rows, "cols": cols, "cell_mm": 100,
                                "bitmap_b64": base64.b64encode(bytes(10)).decode()})
        check("bitmap_b64 长度校验", False, "未报错")
    except m3tl.FrameError:
        check("bitmap_b64 长度校验", True)


def test_payload_len_mismatch() -> None:
    """payload_len 字段与实际 UDP 长度不符：分别偏大/偏小都必须按 length 拒绝。"""
    print("== payload_len 与实际长度不符 ==")
    payload = m3tl.encode_payload(6, {"frames": 5})
    good = m3tl.encode_frame(6, payload, sequence=1, timestamp_ms=1)

    overstated = bytearray(good)
    struct.pack_into("<I", overstated, 8, len(payload) + 1)
    expect_error("payload_len 偏大", bytes(overstated), "length")

    understated = bytearray(good)
    struct.pack_into("<I", understated, 8, len(payload) - 1)
    expect_error("payload_len 偏小", bytes(understated), "length")

    # payload_len 超过上限 1024 也必须拒绝（归类为 payload）。
    over_cap = bytearray(good)
    struct.pack_into("<I", over_cap, 8, m3tl.MAX_PAYLOAD + 1)
    expect_error("payload_len 超上限", bytes(over_cap), "payload")


def test_camera_boundary() -> None:
    """type=6 相机状态：全 0 与全 0xFFFF/0xFFFFFFFF 边界往返，长度错误拒绝。"""
    print("== type=6 相机状态 边界 ==")
    for fields in (
        {"frames": 0, "last_frame_ms": 0, "width": 0, "height": 0},
        {"frames": 0xFFFFFFFF, "last_frame_ms": 0xFFFFFFFF,
         "width": 0xFFFF, "height": 0xFFFF},
    ):
        payload = m3tl.encode_payload(6, fields)
        check("type=6 载荷 12 字节", len(payload) == 12)
        _, decoded = m3tl.decode_message(
            m3tl.encode_frame(6, payload, sequence=1, timestamp_ms=1)
        )
        check(f"type=6 边界往返 {fields['width']}x{fields['height']}", decoded == fields)

    try:
        m3tl.parse_payload(m3tl.Frame(6, 0, 0, 0, bytes(11)))
        check("type=6 长度校验", False, "未报错")
    except m3tl.FrameError as error:
        check("type=6 长度校验", error.reason == "payload")


def test_config_readback() -> None:
    """type=7 配置回读：往返、上边界（0xFFFFFFFF）、长度错误。"""
    print("== type=7 配置回读 ==")
    fields = {"word_index": 0x040, "value": 0xDEADBEEF}
    payload = m3tl.encode_payload(7, fields)
    check("type=7 载荷 8 字节", len(payload) == 8)
    _, decoded = m3tl.decode_message(
        m3tl.encode_frame(7, payload, sequence=3, timestamp_ms=9)
    )
    check("type=7 字段往返一致", decoded == fields, f"得到 {decoded}")

    edge = {"word_index": 0xFFFFFFFF, "value": 0xFFFFFFFF}
    payload = m3tl.encode_payload(7, edge)
    _, decoded = m3tl.decode_message(
        m3tl.encode_frame(7, payload, sequence=4, timestamp_ms=10)
    )
    check("type=7 上边界往返", decoded == edge)

    try:
        m3tl.parse_payload(m3tl.Frame(7, 0, 0, 0, bytes(7)))
        check("type=7 长度校验", False, "未报错")
    except m3tl.FrameError as error:
        check("type=7 长度校验", error.reason == "payload")


def test_unknown_type() -> None:
    print("== 未知类型容忍 ==")
    frame = m3tl.encode_frame(99, b"\x01\x02\x03", sequence=1, timestamp_ms=1)
    decoded_frame, decoded = m3tl.decode_message(frame)
    check("未知类型不报错", True)
    check("未知类型标记", decoded.get("unknown") is True)
    check("未知类型保留 type_id", decoded.get("type_id") == 99)
    check("未知类型保留长度", decoded.get("payload_len") == 3)
    check("已知类型集合不含 4", 4 not in m3tl.KNOWN_TYPES)
    check("已知类型集合", set(m3tl.KNOWN_TYPES) == {1, 2, 3, 5, 6, 7})


def main() -> int:
    print("M3TL v1 自检开始")
    test_header_layout()
    test_crc_reference()
    test_bad_frames()
    test_roundtrip()
    test_grid_bit_order()
    test_grid_two_cell_vector()
    test_payload_len_mismatch()
    test_camera_boundary()
    test_config_readback()
    test_unknown_type()
    print(f"\n通过 {PASSED} 项，失败 {FAILED} 项")
    if FAILED:
        print("FAIL")
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())