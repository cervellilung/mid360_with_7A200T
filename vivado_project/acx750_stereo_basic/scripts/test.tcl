set here [file dirname [file dirname [file normalize [info script]]]]
set repo [file dirname [file dirname $here]]
set logs [file join $repo vivado_project logs stereo_basic]
file mkdir $logs
create_project -force stereo_basic_sim [file join $logs simulation] -part xc7a200tfbg484-2
add_files [glob [file join $here acx750_stereo_basic.srcs sources_1 imports rtl stereo*.sv]]
add_files -fileset sim_1 [file join $here sim tb_stereo_basic.sv]
set_property xsim.simulate.runtime 0ns [get_filesets sim_1]
set simdir [file join $logs simulation stereo_basic_sim.sim sim_1 behav xsim]
file mkdir $simdir
foreach name {gray.hex match.hex} {file copy -force [file join $logs $name] $simdir}
foreach top {tb_stereo_basic} {
 set_property top $top [get_filesets sim_1]
 update_compile_order -fileset sim_1
 launch_simulation -simset sim_1 -mode behavioral
 run all
 close_sim
 set handle [open [file join $simdir simulate.log] r];set body [read $handle];close $handle
 if {[string match {*Fatal:*} $body]||![string match {*PASS *} $body]} {error "Simulation failed: $top"}
 puts "TEST_PASS:$top"
}
close_project
