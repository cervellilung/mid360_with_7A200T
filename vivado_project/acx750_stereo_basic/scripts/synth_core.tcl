# Standard Vivado project for processing-core inspection, not a board image.
set here [file dirname [file dirname [file normalize [info script]]]]
set root [file dirname [file dirname $here]]
set logs [file join $root vivado_project logs stereo_basic synthesis]
file mkdir $logs
set_param general.maxThreads 8
if {[file exists [file join $here acx750_stereo_basic.xpr]]} {
 open_project [file join $here acx750_stereo_basic.xpr]
} else {
 create_project acx750_stereo_basic $here -part xc7a200tfbg484-2
 set_property top stereo_pair_engine [get_filesets sources_1]
 set_property top tb_stereo_basic [get_filesets sim_1]
 set_property STEPS.SYNTH_DESIGN.ARGS.MORE_OPTIONS {-mode out_of_context} [get_runs synth_1]
 set_property target_language Verilog [current_project]
}
foreach source [glob [file join $here acx750_stereo_basic.srcs sources_1 imports rtl stereo*.sv]] {
 if {[llength [get_files -quiet $source]]==0} {add_files -norecurse -fileset sources_1 $source}
}
set vendor [file join $here acx750_stereo_basic.srcs sources_1 imports vendor_camera]
foreach name {camera_init.v ov5640_init_table_rgb.v i2c_control.v i2c_bit_shift.v} {
 set source [file join $vendor $name]
 if {[llength [get_files -quiet $source]]==0} {add_files -norecurse -fileset sources_1 $source}
}
set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO XPM_MEMORY} [current_project]
foreach old [get_files -quiet *tb_n10.sv] {remove_files $old}
foreach tb {tb_stereo_basic.sv tb_frame_store.sv tb_camera_rx.sv tb_camera_init.sv} {
 import_files -force -fileset sim_1 [file join $here sim $tb]
}
import_files -force -fileset constrs_1 [file join $here constraints core_ooc.xdc]
update_compile_order -fileset sources_1
if {[info exists ::env(CORE_PROJECT_ONLY)]&&$::env(CORE_PROJECT_ONLY)==1} {close_project;exit}
if {[info exists ::env(CAPTURE_SYNTH)]&&$::env(CAPTURE_SYNTH)==1} {
 set_property top stereo_dual_capture [get_filesets sources_1]
 update_compile_order -fileset sources_1
 set_property USED_IN_SYNTHESIS false [get_files *core_ooc.xdc]
 set_property USED_IN_IMPLEMENTATION false [get_files *core_ooc.xdc]
 synth_design -top stereo_dual_capture -part xc7a200tfbg484-2 -mode out_of_context
 create_clock -name sys_clk -period 10.000 [get_ports sys_clk]
 create_clock -name ctrl50 -period 20.000 [get_ports clk50]
 create_clock -name camera_xclk -period 41.667 [get_ports xclk24]
 create_clock -name camera0 -period 40.000 [get_ports {pclk[0]}]
 create_clock -name camera1 -period 40.000 [get_ports {pclk[1]}]
 set capture_logs [file join $root vivado_project logs stereo_basic capture_synthesis]
 file mkdir $capture_logs
 report_utilization -file [file join $capture_logs utilization.rpt]
 report_utilization -hierarchical -file [file join $capture_logs hierarchy.rpt]
 report_cdc -details -file [file join $capture_logs cdc.rpt]
 foreach c {sys_clk ctrl50 camera0 camera1} {
  report_timing -from [get_clocks $c] -to [get_clocks $c] -max_paths 5 -file [file join $capture_logs timing_$c.rpt]
 }
 write_checkpoint -force [file join $capture_logs capture_synth.dcp]
 set_property USED_IN_SYNTHESIS true [get_files *core_ooc.xdc]
 set_property USED_IN_IMPLEMENTATION true [get_files *core_ooc.xdc]
 set_property top stereo_pair_engine [get_filesets sources_1]
 update_compile_order -fileset sources_1
 puts "CAPTURE_SYNTH_PASS"
 close_project;exit
}
synth_design -top stereo_pair_engine -part xc7a200tfbg484-2 -mode out_of_context
if {[llength [get_clocks -quiet core_clk]]==0} {create_clock -name core_clk -period 10.000 [get_ports clk]}
report_utilization -file [file join $logs utilization.rpt]
report_utilization -hierarchical -file [file join $logs hierarchy.rpt]
report_timing_summary -file [file join $logs timing.rpt]
report_high_fanout_nets -fanout_greater_than 100 -file [file join $logs fanout.rpt]
report_control_sets -file [file join $logs control_sets.rpt]
write_checkpoint -force [file join $logs stereo_core_synth.dcp]
puts "CORE_SYNTH_PASS"
close_project
