#============================================================================
# acx750_lcd.xdc -- TFT LCD 40pin FPC（RGB565，800x480）
#
# 管脚出处（唯一可信来源）：
#   例程 ch57 ...\constrs_1\new\eth_udp_rgmii_ddr3_tft800x480.xdc 第 33~58 行
#   例程 ch41 ...\constrs_1\new\io.xdc 第 59~79 行（两份完全一致，已交叉核对）
#   TFT_pwm 在例程中接 K13（背光使能）
#
# 共 21 个信号：16 位数据 + clk/de/hs/vs/pwm
# 顶层端口：tft_rgb[15:0] / tft_clk / tft_de / tft_hs / tft_vs / tft_pwm
#============================================================================

#----------------------------------------------------------------------------
# 数据总线 RGB565
#----------------------------------------------------------------------------
set_property PACKAGE_PIN P19 [get_ports {tft_rgb[15]}]
set_property PACKAGE_PIN G17 [get_ports {tft_rgb[14]}]
set_property PACKAGE_PIN R19 [get_ports {tft_rgb[13]}]
set_property PACKAGE_PIN G18 [get_ports {tft_rgb[12]}]
set_property PACKAGE_PIN R18 [get_ports {tft_rgb[11]}]
set_property PACKAGE_PIN K17 [get_ports {tft_rgb[10]}]
set_property PACKAGE_PIN J17 [get_ports {tft_rgb[9]}]
set_property PACKAGE_PIN H17 [get_ports {tft_rgb[8]}]
set_property PACKAGE_PIN H20 [get_ports {tft_rgb[7]}]
set_property PACKAGE_PIN H18 [get_ports {tft_rgb[6]}]
set_property PACKAGE_PIN G20 [get_ports {tft_rgb[5]}]
set_property PACKAGE_PIN H15 [get_ports {tft_rgb[4]}]
set_property PACKAGE_PIN H13 [get_ports {tft_rgb[3]}]
set_property PACKAGE_PIN G13 [get_ports {tft_rgb[2]}]
set_property PACKAGE_PIN G15 [get_ports {tft_rgb[1]}]
set_property PACKAGE_PIN G16 [get_ports {tft_rgb[0]}]

#----------------------------------------------------------------------------
# 控制信号
#----------------------------------------------------------------------------
set_property PACKAGE_PIN J15 [get_ports tft_clk]
set_property PACKAGE_PIN K14 [get_ports tft_de]
set_property PACKAGE_PIN H14 [get_ports tft_hs]
set_property PACKAGE_PIN J14 [get_ports tft_vs]
# 背光使能（K13）；注意：注释必须单独成行——Tcl 只在命令开头把 # 当注释，
# 写在命令后面会被当成多余参数，Vivado 会报 "illegal # option"。
set_property PACKAGE_PIN K13 [get_ports tft_pwm]

#----------------------------------------------------------------------------
# IOSTANDARD
#----------------------------------------------------------------------------
set_property IOSTANDARD LVCMOS33 [get_ports {tft_rgb[15]}]
set_property IOSTANDARD LVCMOS33 [get_ports {tft_rgb[14]}]
set_property IOSTANDARD LVCMOS33 [get_ports {tft_rgb[13]}]
set_property IOSTANDARD LVCMOS33 [get_ports {tft_rgb[12]}]
set_property IOSTANDARD LVCMOS33 [get_ports {tft_rgb[11]}]
set_property IOSTANDARD LVCMOS33 [get_ports {tft_rgb[10]}]
set_property IOSTANDARD LVCMOS33 [get_ports {tft_rgb[9]}]
set_property IOSTANDARD LVCMOS33 [get_ports {tft_rgb[8]}]
set_property IOSTANDARD LVCMOS33 [get_ports {tft_rgb[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {tft_rgb[6]}]
set_property IOSTANDARD LVCMOS33 [get_ports {tft_rgb[5]}]
set_property IOSTANDARD LVCMOS33 [get_ports {tft_rgb[4]}]
set_property IOSTANDARD LVCMOS33 [get_ports {tft_rgb[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {tft_rgb[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {tft_rgb[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {tft_rgb[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports tft_clk]
set_property IOSTANDARD LVCMOS33 [get_ports tft_de]
set_property IOSTANDARD LVCMOS33 [get_ports tft_hs]
set_property IOSTANDARD LVCMOS33 [get_ports tft_vs]
set_property IOSTANDARD LVCMOS33 [get_ports tft_pwm]