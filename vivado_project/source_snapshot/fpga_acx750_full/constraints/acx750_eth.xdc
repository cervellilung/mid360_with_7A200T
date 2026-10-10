#============================================================================
# acx750_eth.xdc -- RTL8211F 千兆以太网（RGMII）+ MDC/MDIO + PHY 复位
#
# 管脚出处（唯一可信来源）：
#   eth_reset_n  P14  例程 ch57 ...\constrs_1\new\eth_udp_rgmii_ddr3_tft800x480.xdc 第 51 行
#   eth_rx_clk   Y18  同上 第 53 行（例程名 rgmii_rx_clk_i）
#   eth_rx_dv    T20  同上 第 54 行（例程名 rgmii_rxdv）
#   eth_rxd[0]   P20  同上 第 62 行
#   eth_rxd[1]   N15  同上 第 61 行
#   eth_rxd[2]   AA18 同上 第 60 行
#   eth_rxd[3]   AB18 同上 第 59 行
#   eth_gtx_clk  AB21 例程 ch50 acx750_eth_udp_tx_rgmii ...\constrs_1\new\io.xdc 第 26 行
#                      （例程名 rgmii_tx_clk；ch45 中另一写法 eth_gtxc 同脚 AB21）
#   eth_txd[0]   AB20 同上 第 22 行
#   eth_txd[1]   Y19  同上 第 25 行
#   eth_txd[2]   AB22 同上 第 24 行
#   eth_txd[3]   W20  同上 第 23 行
#   eth_tx_en    AA19 同上 第 21 行（例程名 rgmii_txen）
#   eth_mdc      R14  例程 ch51 phy_config_mdio ...\constrs_1\new\IO.xdc 第 2 行（mdc）
#   eth_mdio     U21  同上 第 3 行（mdio）
#
# 交叉核对：ch45 ov5640_udp io.xdc 第 78~99 行给出同一组 TX/MDC/MDIO 脚，完全一致。
#============================================================================

#----------------------------------------------------------------------------
# 接收方向（PHY -> FPGA）
#----------------------------------------------------------------------------
set_property PACKAGE_PIN Y18 [get_ports eth_rx_clk]
set_property PACKAGE_PIN T20 [get_ports eth_rx_dv]
set_property PACKAGE_PIN P20 [get_ports {eth_rxd[0]}]
set_property PACKAGE_PIN N15 [get_ports {eth_rxd[1]}]
set_property PACKAGE_PIN AA18 [get_ports {eth_rxd[2]}]
set_property PACKAGE_PIN AB18 [get_ports {eth_rxd[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports eth_rx_clk]
set_property IOSTANDARD LVCMOS33 [get_ports eth_rx_dv]
set_property IOSTANDARD LVCMOS33 [get_ports {eth_rxd[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {eth_rxd[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {eth_rxd[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {eth_rxd[3]}]

#----------------------------------------------------------------------------
# 发送方向（FPGA -> PHY）
#----------------------------------------------------------------------------
set_property PACKAGE_PIN AB21 [get_ports eth_gtx_clk]
set_property PACKAGE_PIN AA19 [get_ports eth_tx_en]
set_property PACKAGE_PIN AB20 [get_ports {eth_txd[0]}]
set_property PACKAGE_PIN Y19 [get_ports {eth_txd[1]}]
set_property PACKAGE_PIN AB22 [get_ports {eth_txd[2]}]
set_property PACKAGE_PIN W20 [get_ports {eth_txd[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports eth_gtx_clk]
set_property IOSTANDARD LVCMOS33 [get_ports eth_tx_en]
set_property IOSTANDARD LVCMOS33 [get_ports {eth_txd[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {eth_txd[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {eth_txd[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {eth_txd[3]}]

#----------------------------------------------------------------------------
# PHY 管理接口 + 复位
#----------------------------------------------------------------------------
set_property PACKAGE_PIN R14 [get_ports eth_mdc]
set_property PACKAGE_PIN U21 [get_ports eth_mdio]
set_property PACKAGE_PIN P14 [get_ports eth_reset_n]
set_property IOSTANDARD LVCMOS33 [get_ports eth_mdc]
# eth_mdio 为 inout 三态。例程（ch51/ch45）只写了 IOSTANDARD LVCMOS33，
# 未显式声明 PULLUP；RTL8211F 一侧通常已有外部上拉电阻，故此处照抄例程，不加 PULLUP。
set_property IOSTANDARD LVCMOS33 [get_ports eth_mdio]
set_property IOSTANDARD LVCMOS33 [get_ports eth_reset_n]

#----------------------------------------------------------------------------
# eth_rx_clk 由 PHY 提供，走普通 IO 而非专用时钟管脚，需关闭专用时钟布线要求。
#
# ⚠️ XDC 是 Tcl 的**受限子集**，`if` / `set` / 变量都不支持
#    （Vivado 会报 `Designutils 20-1307 Command 'if' is not supported` 并把整条约束丢掉）。
#    所以这里只用**单条表达式**：直接取该端口所连的 net，写成一行，
#    既不会空匹配、也不需要分支。
#----------------------------------------------------------------------------
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -of_objects [get_ports eth_rx_clk]]

#----------------------------------------------------------------------------
# eth_rx_clk 为输入时钟，RGMII 125MHz -> 8.000 ns
#----------------------------------------------------------------------------
create_clock -name eth_rx_clk -period 8.000 [get_ports eth_rx_clk]

#----------------------------------------------------------------------------
# 关于 eth_gtx_clk（125MHz 发送时钟）：
#   该时钟由 ODDR 原语从内部时钟（clk_sys 派生）生成后送出，属于"派生时钟"，
#   其相位/频率关系由 Vivado 自动从 ODDR 源时钟推导。
#   因此这里【不】对 eth_gtx_clk create_clock，否则会与自动派生的生成时钟冲突。
#----------------------------------------------------------------------------