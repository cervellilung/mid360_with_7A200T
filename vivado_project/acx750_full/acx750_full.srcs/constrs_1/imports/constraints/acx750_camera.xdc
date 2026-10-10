#============================================================================
# acx750_camera.xdc -- CMOS 摄像头 DVP 接口（OV5640）
#
# 管脚出处（唯一可信来源）：
#   例程 ch41 acx750_ov5640_ddr3_tft_32bit ...\constrs_1\new\io.xdc
#     第 23~36 行（PACKAGE_PIN）、第 39~56 行（IOSTANDARD / PULLUP / CLOCK_DEDICATED_ROUTE）
#   ch44 / ch45 中同一组摄像头脚完全一致，已交叉核对。
#
#   cam_data[7]=M16  cam_data[6]=M18  cam_data[5]=L18  cam_data[4]=L16
#   cam_data[3]=K16  cam_data[2]=K19  cam_data[1]=N20  cam_data[0]=M20
#   cam_href=N18  cam_vsync=N19  cam_pclk=K18  cam_xclk=M15
#   cam_sclk=J16  cam_sdat=M17
#============================================================================

#----------------------------------------------------------------------------
# 8 位并行数据
#----------------------------------------------------------------------------
set_property PACKAGE_PIN M16 [get_ports {cam_data[7]}]
set_property PACKAGE_PIN M18 [get_ports {cam_data[6]}]
set_property PACKAGE_PIN L18 [get_ports {cam_data[5]}]
set_property PACKAGE_PIN L16 [get_ports {cam_data[4]}]
set_property PACKAGE_PIN K16 [get_ports {cam_data[3]}]
set_property PACKAGE_PIN K19 [get_ports {cam_data[2]}]
set_property PACKAGE_PIN N20 [get_ports {cam_data[1]}]
set_property PACKAGE_PIN M20 [get_ports {cam_data[0]}]

#----------------------------------------------------------------------------
# 同步 / 时钟
#----------------------------------------------------------------------------
set_property PACKAGE_PIN N18 [get_ports cam_href]
set_property PACKAGE_PIN N19 [get_ports cam_vsync]
set_property PACKAGE_PIN K18 [get_ports cam_pclk]
set_property PACKAGE_PIN M15 [get_ports cam_xclk]

#----------------------------------------------------------------------------
# SCCB（I2C）控制
#----------------------------------------------------------------------------
set_property PACKAGE_PIN J16 [get_ports cam_sclk]
set_property PACKAGE_PIN M17 [get_ports cam_sdat]

#----------------------------------------------------------------------------
# IOSTANDARD 与上拉（照抄例程）
#----------------------------------------------------------------------------
set_property IOSTANDARD LVCMOS33 [get_ports {cam_data[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {cam_data[6]}]
set_property IOSTANDARD LVCMOS33 [get_ports {cam_data[5]}]
set_property IOSTANDARD LVCMOS33 [get_ports {cam_data[4]}]
set_property IOSTANDARD LVCMOS33 [get_ports {cam_data[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {cam_data[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {cam_data[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {cam_data[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports cam_href]
set_property IOSTANDARD LVCMOS33 [get_ports cam_vsync]
set_property IOSTANDARD LVCMOS33 [get_ports cam_pclk]
set_property IOSTANDARD LVCMOS33 [get_ports cam_xclk]
set_property IOSTANDARD LVCMOS33 [get_ports cam_sclk]
set_property IOSTANDARD LVCMOS33 [get_ports cam_sdat]
set_property PULLUP true [get_ports cam_sdat]
set_property PULLUP true [get_ports cam_sclk]

#----------------------------------------------------------------------------
# cam_pclk 由摄像头驱动、走普通 IO，关闭专用时钟布线要求
# （照抄例程，例程用 camera_pclk_IBUF，本项目端口名 cam_pclk，故 net 名为 cam_pclk_IBUF）
#----------------------------------------------------------------------------
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets cam_pclk_IBUF]