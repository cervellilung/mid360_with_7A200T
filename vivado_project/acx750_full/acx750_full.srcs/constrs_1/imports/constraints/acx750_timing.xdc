#============================================================================
# acx750_timing.xdc -- 时钟域关系
#
# 说明：本文件只做"时钟域之间"的关系声明，不定义派生时钟的周期。
#   * 主输入时钟 clk50m 的 create_clock 在 acx750_pins.xdc（50MHz，20ns）
#   * eth_rx_clk 的 create_clock 在 acx750_eth.xdc（125MHz，8ns）
#   * clk_sys(100MHz) / clk_pix(33MHz) / DDR3 用 200MHz 均由 PLL/MMCM/MIG 从
#     同一个 50MHz 晶振派生，是"自动派生时钟"，禁止手动 create_clock
#     （手动创建会与 Vivado 自动推导的生成时钟冲突）。
#============================================================================

#----------------------------------------------------------------------------
# 摄像头像素时钟 cam_pclk
#   这是外部 OV5640 送进来的输入时钟，不是 MMCM 派生，必须建立时钟对象，
#   下面的 set_clock_groups 才能引用它。
#   注意：这里 20.000ns(50MHz) 是占位值，OV5640 实际 PCLK 取决于其内部 PLL 配置，
#        需查 OV5640 配置表后回填（见 README「待确认」）。
#----------------------------------------------------------------------------
create_clock -name cam_pclk -period 20.000 [get_ports cam_pclk]

#----------------------------------------------------------------------------
# 异步时钟域分组（-asynchronous）
#
# 判断依据：
#   1) 3 个组之间的时钟来自互不相关的振荡源，不存在固定相位关系：
#        - 组 A：clk50m 及其派生的 clk_sys / clk_pix（同一晶振 + 同一 MMCM，
#                彼此同步，因此必须放在【同一个】组里，绝不能把 clk_pix 单独
#                设为异步——否则会切断本该分析的跨域路径）
#        - 组 B：eth_rx_clk 由外部 RTL8211F PHY 的 RGMII 恢复/输出，与本地晶振无固定相位
#        - 组 C：cam_pclk  由外部 OV5640 输出，与本地晶振无固定相位
#   2) DDR3 的 200MHz 时钟由 MIG 从 clk50m 派生，与 clk_sys 同源，属同步，故不单列，
#      随组 A 一起被 Vivado 自动视为同步域。
#----------------------------------------------------------------------------
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks clk50m] \
    -group [get_clocks -include_generated_clocks eth_rx_clk] \
    -group [get_clocks -include_generated_clocks cam_pclk]

#----------------------------------------------------------------------------
# 关于 DRC 降级（NSTD-1 / UCIO-1 / REQP-1839 等）：本工程【暂不添加】。
#   依据：例程 ch51 的 IO.xdc 之所以把 NSTD-1/RTSTAT-1/UCIO-1 降为 Warning，是因为
#   该工程存在只声明 IOSTANDARD 而无 PACKAGE_PIN 的调试端口（phy_init_done、rddata 等）。
#   本项目所有端口均在约束中同时给出了 PACKAGE_PIN 与 IOSTANDARD，不会触发这些 DRC；
#   如综合/实现阶段确实报出与本设计相关的 DRC，再按实际报错信息逐条评估后添加。
#----------------------------------------------------------------------------
# MDIO divider: 100 MHz / (2 * 25) = 2 MHz internal shift clock.
create_generated_clock -name mdio_shift_clk -source [get_pins u_phy_cfg/mdc_clk_reg/C] -divide_by 50 [get_pins u_phy_cfg/mdc_clk_reg/Q]

# AR bundled-data transfer. holding and req change on the same control edge.
# The destination samples only after 3 request synchronizer stages, at SOF.
# HDMI 51.25 MHz: three-stage request plus SOF commit gives >= 3 pixel periods.
# Bound bundled data to 38 ns (< 2 pixel periods), leaving >= 1 period margin.
# This is tighter than the old 60 ns constraint; the 33.333 MHz fallback is safe too.
# Only holding-bank paths are relaxed; active pixel rendering stays single-cycle.
set ar_holding [get_cells -hier -filter {NAME =~ *u_ar/u_engine/overlay/holding_reg* && REF_NAME =~ FD*}]
set ar_pixel_pins [get_pins -hier -filter {NAME =~ *u_ar/u_engine/overlay/m_data_reg*/C}]
set ar_pixel_clock [get_clocks -of_objects $ar_pixel_pins]
set ar_dest [all_registers -clock $ar_pixel_clock]
set_max_delay -datapath_only 38.000 -from $ar_holding -to $ar_dest
