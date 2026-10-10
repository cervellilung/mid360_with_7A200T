#============================================================================
# acx750_pins.xdc -- 时钟 / 复位 / LED / 串口
# 芯片：XC7A200T-FBG484-2（小梅哥 ACX750）
#
# 管脚出处（唯一可信来源）：
#   clk50m      W19  例程 ch57 ...\constrs_1\new\eth_udp_rgmii_ddr3_tft800x480.xdc 第 50 行
#   btn_reset_n D21  例程 ch57 同上 第 52 行（例程名 reset_n，S4 按键，低有效）
#   led[3:0]    W22/W21/V22/U22  例程 ch41 ...\constrs_1\new\io.xdc 第 17~20 行
#   uart_txd    M21  例程 ch50 eth_udp_rx_rgmii ...\constrs_1\new\io.xdc 第 29 行（uart_tx）
#   uart_rxd    L21  四处独立出处（2026-10-01 补齐）：
#                    ① 厂商整板约束 ACX750例程\盘A_...\04_引脚功能信息\ACX750_CB_PIN.xdc 第 39 行
#                       「PACKAGE_PIN L21 [get_ports UART_RXD]」
#                    ② 例程 ch06_acx750_uart_rx.rar 的 uart_rx_test_pin.xdc 第 13 行
#                    ③ 例程 ch09_acx750_uart_loopback.rar 的 IO.xdc 第 13 行
#                    ④ 厂商《ACX750开发板管脚信息表.xlsx》（UART_RXD）
#                    详见 constraints/README.md 与 docs/ 下的管脚查证报告（pin_hunt_uart_gpio.md）
#============================================================================

#----------------------------------------------------------------------------
# 未使用管脚：例程统一样式（ch57/ch50/ch41 均第一行相同）
#----------------------------------------------------------------------------
set_property BITSTREAM.CONFIG.UNUSEDPIN Pullnone [current_design]

#----------------------------------------------------------------------------
# 50MHz 有源晶振（系统主输入时钟）
#----------------------------------------------------------------------------
set_property PACKAGE_PIN W19 [get_ports clk50m]
set_property IOSTANDARD LVCMOS33 [get_ports clk50m]

#----------------------------------------------------------------------------
# 按键复位（S4，低有效）
#----------------------------------------------------------------------------
set_property PACKAGE_PIN D21 [get_ports btn_reset_n]
set_property IOSTANDARD LVCMOS33 [get_ports btn_reset_n]

#----------------------------------------------------------------------------
# 4 颗用户 LED
#----------------------------------------------------------------------------
set_property PACKAGE_PIN W22 [get_ports {led[3]}]
set_property PACKAGE_PIN W21 [get_ports {led[2]}]
set_property PACKAGE_PIN V22 [get_ports {led[1]}]
set_property PACKAGE_PIN U22 [get_ports {led[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[0]}]

#----------------------------------------------------------------------------
# 串口 CH9102（调试串口，115200 8N1）
# TX/RX 均有权威出处，见文件头
#----------------------------------------------------------------------------
set_property PACKAGE_PIN M21 [get_ports uart_txd]
set_property IOSTANDARD LVCMOS33 [get_ports uart_txd]
set_property PACKAGE_PIN L21 [get_ports uart_rxd]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rxd]

#----------------------------------------------------------------------------
# 主输入时钟约束：50MHz -> 20.000 ns
#----------------------------------------------------------------------------
create_clock -name clk50m -period 20.000 [get_ports clk50m]