#============================================================================
# acx750_ddr3.xdc -- DDR3 32bit 管脚 + IOSTANDARD
#
# 唯一可信来源：例程 ch57 的 acx750_core_ddr3_pin.ucf（32bit 版本）
#   ch57_acx750_eth_udp_rgmii_ddr3_tft800x480\...\eth_udp_rgmii_ddr3_tft800x480_32bit\
#     acx750_core_ddr3_pin.ucf
#   （该 UCF 整份重复了两遍，本文件已去重）
#
# 规则：
#   * ddr3_reset_n = LVCMOS15，其余单端 = SSTL15，差分对 = DIFF_SSTL15
#   * 本文件只放管脚与 IOSTANDARD；
#     DDR3 的内部时序约束（input/output delay、phase 等）由 MIG IP 自带的 XDC 负责，
#     此处【不】重复编写，避免与 MIG 冲突。
#============================================================================

#----------------------------------------------------------------------------
# 地址 Address  ddr3_addr[14:0]
#----------------------------------------------------------------------------
set_property PACKAGE_PIN Y2  [get_ports {ddr3_addr[0]}]
set_property PACKAGE_PIN AB3 [get_ports {ddr3_addr[1]}]
set_property PACKAGE_PIN Y1  [get_ports {ddr3_addr[2]}]
set_property PACKAGE_PIN U1  [get_ports {ddr3_addr[3]}]
set_property PACKAGE_PIN AA4 [get_ports {ddr3_addr[4]}]
set_property PACKAGE_PIN W1  [get_ports {ddr3_addr[5]}]
set_property PACKAGE_PIN AB5 [get_ports {ddr3_addr[6]}]
set_property PACKAGE_PIN R2  [get_ports {ddr3_addr[7]}]
set_property PACKAGE_PIN AB2 [get_ports {ddr3_addr[8]}]
set_property PACKAGE_PIN W2  [get_ports {ddr3_addr[9]}]
set_property PACKAGE_PIN Y3  [get_ports {ddr3_addr[10]}]
set_property PACKAGE_PIN AA1 [get_ports {ddr3_addr[11]}]
set_property PACKAGE_PIN AA3 [get_ports {ddr3_addr[12]}]
set_property PACKAGE_PIN U2  [get_ports {ddr3_addr[13]}]
set_property PACKAGE_PIN AB1 [get_ports {ddr3_addr[14]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_addr[0]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_addr[1]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_addr[2]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_addr[3]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_addr[4]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_addr[5]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_addr[6]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_addr[7]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_addr[8]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_addr[9]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_addr[10]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_addr[11]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_addr[12]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_addr[13]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_addr[14]}]

#----------------------------------------------------------------------------
# Bank 地址 ddr3_ba[2:0]
#----------------------------------------------------------------------------
set_property PACKAGE_PIN R3 [get_ports {ddr3_ba[0]}]
set_property PACKAGE_PIN Y4 [get_ports {ddr3_ba[1]}]
set_property PACKAGE_PIN V2 [get_ports {ddr3_ba[2]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_ba[0]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_ba[1]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_ba[2]}]

#----------------------------------------------------------------------------
# 命令 / 控制
#----------------------------------------------------------------------------
set_property PACKAGE_PIN U3  [get_ports ddr3_ras_n]
set_property PACKAGE_PIN W6  [get_ports ddr3_cas_n]
set_property PACKAGE_PIN V3  [get_ports ddr3_we_n]
set_property PACKAGE_PIN AA5 [get_ports {ddr3_cke[0]}]
set_property PACKAGE_PIN U5  [get_ports {ddr3_cs_n[0]}]
set_property PACKAGE_PIN T5  [get_ports {ddr3_odt[0]}]
set_property IOSTANDARD SSTL15 [get_ports ddr3_ras_n]
set_property IOSTANDARD SSTL15 [get_ports ddr3_cas_n]
set_property IOSTANDARD SSTL15 [get_ports ddr3_we_n]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_cke[0]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_cs_n[0]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_odt[0]}]

#----------------------------------------------------------------------------
# 差分时钟 ddr3_ck_p[0] / ddr3_ck_n[0]
#----------------------------------------------------------------------------
set_property PACKAGE_PIN V4 [get_ports {ddr3_ck_p[0]}]
set_property PACKAGE_PIN W4 [get_ports {ddr3_ck_n[0]}]
set_property IOSTANDARD DIFF_SSTL15 [get_ports {ddr3_ck_p[0]}]
set_property IOSTANDARD DIFF_SSTL15 [get_ports {ddr3_ck_n[0]}]

#----------------------------------------------------------------------------
# 复位（注意：reset_n 是 LVCMOS15，不是 SSTL15）
#----------------------------------------------------------------------------
set_property PACKAGE_PIN T1 [get_ports ddr3_reset_n]
set_property IOSTANDARD LVCMOS15 [get_ports ddr3_reset_n]

#----------------------------------------------------------------------------
# 数据掩码 ddr3_dm[3:0]
#----------------------------------------------------------------------------
set_property PACKAGE_PIN F3 [get_ports {ddr3_dm[0]}]
set_property PACKAGE_PIN H3 [get_ports {ddr3_dm[1]}]
set_property PACKAGE_PIN M3 [get_ports {ddr3_dm[2]}]
set_property PACKAGE_PIN N2 [get_ports {ddr3_dm[3]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dm[0]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dm[1]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dm[2]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dm[3]}]

#----------------------------------------------------------------------------
# 数据总线 ddr3_dq[31:0]
#----------------------------------------------------------------------------
set_property PACKAGE_PIN C2 [get_ports {ddr3_dq[0]}]
set_property PACKAGE_PIN E2 [get_ports {ddr3_dq[1]}]
set_property PACKAGE_PIN B2 [get_ports {ddr3_dq[2]}]
set_property PACKAGE_PIN G1 [get_ports {ddr3_dq[3]}]
set_property PACKAGE_PIN B1 [get_ports {ddr3_dq[4]}]
set_property PACKAGE_PIN F1 [get_ports {ddr3_dq[5]}]
set_property PACKAGE_PIN A1 [get_ports {ddr3_dq[6]}]
set_property PACKAGE_PIN D2 [get_ports {ddr3_dq[7]}]
set_property PACKAGE_PIN H2 [get_ports {ddr3_dq[8]}]
set_property PACKAGE_PIN G3 [get_ports {ddr3_dq[9]}]
set_property PACKAGE_PIN H4 [get_ports {ddr3_dq[10]}]
set_property PACKAGE_PIN G2 [get_ports {ddr3_dq[11]}]
set_property PACKAGE_PIN H5 [get_ports {ddr3_dq[12]}]
set_property PACKAGE_PIN J1 [get_ports {ddr3_dq[13]}]
set_property PACKAGE_PIN J5 [get_ports {ddr3_dq[14]}]
set_property PACKAGE_PIN K1 [get_ports {ddr3_dq[15]}]
set_property PACKAGE_PIN K6 [get_ports {ddr3_dq[16]}]
set_property PACKAGE_PIN L5 [get_ports {ddr3_dq[17]}]
set_property PACKAGE_PIN J6 [get_ports {ddr3_dq[18]}]
set_property PACKAGE_PIN L4 [get_ports {ddr3_dq[19]}]
set_property PACKAGE_PIN K3 [get_ports {ddr3_dq[20]}]
set_property PACKAGE_PIN L3 [get_ports {ddr3_dq[21]}]
set_property PACKAGE_PIN J4 [get_ports {ddr3_dq[22]}]
set_property PACKAGE_PIN M2 [get_ports {ddr3_dq[23]}]
set_property PACKAGE_PIN P1 [get_ports {ddr3_dq[24]}]
set_property PACKAGE_PIN N5 [get_ports {ddr3_dq[25]}]
set_property PACKAGE_PIN P2 [get_ports {ddr3_dq[26]}]
set_property PACKAGE_PIN M5 [get_ports {ddr3_dq[27]}]
set_property PACKAGE_PIN P6 [get_ports {ddr3_dq[28]}]
set_property PACKAGE_PIN M6 [get_ports {ddr3_dq[29]}]
set_property PACKAGE_PIN R1 [get_ports {ddr3_dq[30]}]
set_property PACKAGE_PIN N4 [get_ports {ddr3_dq[31]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dq[0]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dq[1]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dq[2]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dq[3]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dq[4]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dq[5]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dq[6]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dq[7]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dq[8]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dq[9]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dq[10]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dq[11]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dq[12]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dq[13]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dq[14]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dq[15]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dq[16]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dq[17]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dq[18]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dq[19]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dq[20]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dq[21]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dq[22]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dq[23]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dq[24]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dq[25]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dq[26]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dq[27]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dq[28]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dq[29]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dq[30]}]
set_property IOSTANDARD SSTL15 [get_ports {ddr3_dq[31]}]

#----------------------------------------------------------------------------
# 数据选通差分对 ddr3_dqs_p[3:0] / ddr3_dqs_n[3:0]
#----------------------------------------------------------------------------
set_property PACKAGE_PIN E1 [get_ports {ddr3_dqs_p[0]}]
set_property PACKAGE_PIN K2 [get_ports {ddr3_dqs_p[1]}]
set_property PACKAGE_PIN M1 [get_ports {ddr3_dqs_p[2]}]
set_property PACKAGE_PIN P5 [get_ports {ddr3_dqs_p[3]}]
set_property PACKAGE_PIN D1 [get_ports {ddr3_dqs_n[0]}]
set_property PACKAGE_PIN J2 [get_ports {ddr3_dqs_n[1]}]
set_property PACKAGE_PIN L1 [get_ports {ddr3_dqs_n[2]}]
set_property PACKAGE_PIN P4 [get_ports {ddr3_dqs_n[3]}]
set_property IOSTANDARD DIFF_SSTL15 [get_ports {ddr3_dqs_p[0]}]
set_property IOSTANDARD DIFF_SSTL15 [get_ports {ddr3_dqs_p[1]}]
set_property IOSTANDARD DIFF_SSTL15 [get_ports {ddr3_dqs_p[2]}]
set_property IOSTANDARD DIFF_SSTL15 [get_ports {ddr3_dqs_p[3]}]
set_property IOSTANDARD DIFF_SSTL15 [get_ports {ddr3_dqs_n[0]}]
set_property IOSTANDARD DIFF_SSTL15 [get_ports {ddr3_dqs_n[1]}]
set_property IOSTANDARD DIFF_SSTL15 [get_ports {ddr3_dqs_n[2]}]
set_property IOSTANDARD DIFF_SSTL15 [get_ports {ddr3_dqs_n[3]}]