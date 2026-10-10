#============================================================================
# acx750_chassis.xdc -- 底盘串口（走 40 针扩展口 P11 的 GPIO0）
#
# 管脚出处（权威整板约束）：
#   ACX750例程\盘A_ACX750开发板标准配套资料\04_引脚功能信息\ACX750_CB_PIN.xdc
#     第 229 行：「set_property PACKAGE_PIN A15 [get_ports GPIO0[34]]」
#     第 230 行：「set_property PACKAGE_PIN A16 [get_ports GPIO0[35]]」
#   即 GPIO0_34 = A15、GPIO0_35 = A16，两者均属 Bank16（B16_L9_P/N）的
#   LVCMOS33 普通 IO，分别引到底板 40 针排针 P11 的第 39 / 40 针。
#   逐针读图复核见 docs/pin_hunt_uart_gpio.md §3（底板原理图 CB p10「LVDS」：
#   P11-39 = B16_L9_P = A15、P11-40 = B16_L9_N = A16）。
#
# 命名与方向约定（延续旧 AC880：P7-39 = FPGA→底盘 RX，P7-40 = 底盘 TX→FPGA）：
#   chassis_txd = A15 = GPIO0_34 = P11-39  （FPGA 输出 → 底盘 RX）
#   chassis_rxd = A16 = GPIO0_35 = P11-40  （底盘 TX → FPGA 输入）
#   端口名必须与顶层 acx750_full_top.sv 的 chassis_txd / chassis_rxd 一致。
#
# 警告：
#   * 旧 AC880 用的 W6/W5 在 ACX750 上分别是 DDR3_CAS / DDR3 区信号
#     （ACX750_CB_PIN.xdc 第 251 行 DDR3_CAS = W6），绝不可沿用。
#   * 上板前必须：与底盘共地；用万用表核对 P11-39/40 空闲电平约 3.3V
#     才可直连（若为 5V 需加电平转换）；只接 TX/RX/GND，不从排针取电。
#============================================================================

set_property PACKAGE_PIN A15 [get_ports chassis_txd]
set_property IOSTANDARD LVCMOS33 [get_ports chassis_txd]
set_property PACKAGE_PIN A16 [get_ports chassis_rxd]
set_property IOSTANDARD LVCMOS33 [get_ports chassis_rxd]