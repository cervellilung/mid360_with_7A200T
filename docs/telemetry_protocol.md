# PS 到电脑/树莓派的 UDP 遥测协议 v1

板端地址固定为 `10.42.0.2/24`，当前电脑或后续树莓派使用 `10.42.0.1/24`，UDP 目的端口
`46000`。此通道传输经过 PL 处理的低带宽结果，不发送
原始视频或原始点云。

所有多字节整数均为小端。32 字节帧头为：

| 偏移 | 字段 | 类型 | 说明 |
|---:|---|---|---|
| 0 | magic | char[4] | `M3TL` |
| 4 | version | u8 | `1` |
| 5 | type | u8 | 1 心跳，2 底盘，3 目标，5 栅格，6 相机状态，7 配置回读 |
| 6 | flags | u16 | 保留 |
| 8 | payload_len | u32 | 最大 1024 |
| 12 | sequence | u32 | 每类消息独立递增 |
| 16 | timestamp_ms | u64 | PS 单调毫秒 |
| 24 | header_crc32 | u32 | 对偏移 0～23 计算 CRC-32 |
| 28 | payload_crc32 | u32 | 对载荷计算 CRC-32 |

CRC 与 Python `zlib.crc32` 一致。总 UDP 载荷最大 1056 字节。接收端要求 UDP 长度必须
严格等于 `32 + payload_len`。

目标消息先放 4 字节头 `count:u8, overflow:u8, reserved:u16`，随后最多 32 条固定 16
字节记录：`id:u8, flags:u8, x_min:i16, x_max:i16, y_min:i16, y_max:i16,
z_min:i16, z_max:i16, nearest_mm:u16`。32 个目标时载荷为 516 字节。

当前底盘消息直接保留现有 DFLink 整数单位：`yaw_q10000`、`body_vx_q5000`、
`body_vy_q5000`、毫米位置及底盘毫秒时间。协议实现以
`pc_telemetry/protocol.py` 为可执行参考；C 端必须逐字节打包，不能直接依赖编译器结构体布局。

## 类型补充（2026-10-01，ACX750 迁移后口径）

> 说明：`type=4` 在旧文档里写过"相机状态"，实际实现未采用，**保留不用**；
> 相机状态改用 `type=6`。这一节与 `fpga_acx750/host/m3tl.py` 的实现一致，
> 两者必须同步修改。

### type=1 心跳（载荷 16 字节）

`pll_locked:u8, ddr3_calib_done:u8, eth_link_up:u8, cam_init_done:u8,
stage:u8, reserved:u8[3], uptime_ms:u32, drop_count:u32`

### type=2 底盘（载荷 16 字节）

`yaw_q10000:i32, body_vx_q5000:i32, body_vy_q5000:i32, chassis_ms:u32`

### type=5 栅格（载荷 8 + 413 = 421 字节）

55 行 × 60 列占据栅格，**位图压缩**（不发送逐格字节，否则超过单包上限）。

| 偏移 | 字段 | 类型 | 说明 |
|---:|---|---|---|
| 0 | rows | u8 | 固定 55 |
| 1 | cols | u8 | 固定 60 |
| 2 | cell_mm | u16 | 每格边长，默认 100 |
| 4 | reserved | u32 | 保留 0 |
| 8 | bitmap | u8[413] | 行优先位图，`ceil(55*60/8)=413` |

位序：第 `r` 行第 `c` 列（均从 0 起）对应字节下标 `(r*60+c)//8` 的
`bit ((r*60+c)%8)`，即**每字节 bit0 先**。

### type=6 相机状态（载荷 12 字节）

`frames:u32, last_frame_ms:u32, width:u16, height:u16`

### type=7 配置回读（载荷 8 字节）

| 偏移 | 字段 | 类型 | 说明 |
|---:|---|---|---|
| 0 | word_index | u32 | 32-bit 字地址（小端）；**AXI 字节地址 = word_index × 4** |
| 4 | value | u32 | 该字读回值（小端） |

这是 PL 对「树莓派下行配置读请求」的应答，`word_index` 覆盖 `perception_regs`
的 4 KiB 寄存器空间。下行配置协议（`UDP → PL:56300`）的细节见
`fpga_acx750_full/docs/control_plane_750.md`。载荷 `payload_len = 8`，总 UDP 载荷
`tx_len = 40`；sequence 与其它类型独立递增。
