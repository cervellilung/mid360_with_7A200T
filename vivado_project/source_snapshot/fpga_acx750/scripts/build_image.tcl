#============================================================================
# build_image.tcl -- ACX750 综合 -> 实现 -> 时序/DRC 门限 -> 出 bit
#
# 前置：先跑过 scripts/build_project.tcl 生成 build/acx750/acx750.xpr
#
# 用法（Vivado 2018.3，batch 模式）：
#   vivado.bat -mode batch -source scripts/build_image.tcl
#   vivado.bat -mode batch -source scripts/build_image.tcl -tclargs -jobs 8
#   vivado.bat -mode batch -source scripts/build_image.tcl -tclargs -jobs 8 -route-only
#     （-route-only：综合必须已完成，只跑实现到布线，用于反复调时序）
#
# 说明：实现 + 布线 + 出 bit 耗时较长（视机器 10~40 分钟），本脚本不内置超时，
#       如需超时控制请在外部包裹（例如用 run_vivado.ps1，或终端 timeout / 后台运行）。
#       -jobs N 控制综合/实现的并行线程数。
#
# 判定标记（全部打到 stdout，不用退出码判成败）：
#   SYNTH_STATUS=...      综合状态
#   RESOURCE_GATE LUT=.. FF=.. BRAM36=.. BRAM18=.. DSP=..
#   ROUTE_STATUS=...      布线运行状态
#   ROUTED_WNS=.. ROUTED_WHS=.. DRC_BAD=..
#   BIT_RUN_STATUS=...    write_bitstream 运行状态
#   BIT_READY=<path>      出 bit 成功，bit 路径
#   BIT_SKIPPED=<原因>    门限没过，跳过出 bit
#
# 200T 门限：LUT<=134600 FF<=269200 BRAM(2*36+18)<=730 DSP<=740
#            ROUTED_WNS>=0 且 ROUTED_WHS>=0 且 DRC_BAD==0
#============================================================================

set root      [file normalize [file join [file dirname [info script]] ..]]
set build_dir [file join $root build]
set proj_dir  [file join $build_dir acx750]
set xpr       [file join $proj_dir acx750.xpr]
set out_dir   [file join $root output]
set snap_file [file join $build_dir source_snapshot.txt]
file mkdir $build_dir
file mkdir $out_dir

if {![file exists $xpr]} {
    error "工程不存在，请先跑 scripts/build_project.tcl：$xpr"
}

#----------------------------------------------------------------------------
# 参数
#----------------------------------------------------------------------------
set jobs       10
set route_only 0
for {set i 0} {$i < [llength $argv]} {incr i} {
    set a [lindex $argv $i]
    switch -- $a {
        -jobs       { incr i; set jobs [lindex $argv $i] }
        -route-only { set route_only 1 }
    }
}
set_param general.maxThreads $jobs
puts "INFO: root=$root jobs=$jobs route_only=$route_only"

open_project $xpr

# 资源门限（XC7A200T）
set GATE_LUT  134600
set GATE_FF   269200
set GATE_BRAM 730
set GATE_DSP  740
puts "GATE: LUT<=$GATE_LUT FF<=$GATE_FF BRAM<=$GATE_BRAM DSP<=$GATE_DSP"

proc write_snapshot {snap_file files} {
    set fd [open $snap_file w]
    foreach f [lsort $files] {
        if {[file isfile $f]} { puts $fd "[file normalize $f]\t[file mtime $f]\t[file size $f]" }
    }
    close $fd
}
proc check_snapshot {snap_file} {
    set changed {}
    if {![file exists $snap_file]} { return {} }
    set fd [open $snap_file r]; set lines [split [read $fd] "\n"]; close $fd
    foreach line $lines {
        if {[string trim $line] eq ""} { continue }
        lassign [split $line "\t"] p mt sz
        if {![file isfile $p]} { lappend changed "$p(removed)"; continue }
        if {[file mtime $p] != $mt || [file size $p] != $sz} { lappend changed $p }
    }
    return $changed
}

#----------------------------------------------------------------------------
# 源码快照：若 build_project 已有快照则复用校验；否则现场生成（RTL+约束）
#----------------------------------------------------------------------------
if {![file exists $snap_file]} {
    set srcs [list]
    foreach f [get_files -of [get_filesets sources_1]] {
        set p [get_property NAME $f]
        if {[file isfile $p] && [string match -nocase *.sv* $p]} { lappend srcs $p }
        if {[file isfile $p] && [string match -nocase *.v $p]}  { lappend srcs $p }
    }
    foreach f [get_files -of [get_filesets constrs_1]] {
        set p [get_property NAME $f]
        if {[file isfile $p]} { lappend srcs $p }
    }
    write_snapshot $snap_file $srcs
    puts "SNAPSHOT_WRITTEN=$snap_file"
}

#----------------------------------------------------------------------------
# 综合（若已完成且需要 route_only 则复用；否则重跑）
#----------------------------------------------------------------------------
set synth_status [get_property STATUS [get_runs synth_1]]
set synth_done [expr {[string match {*Complete*} $synth_status] && ![string match {*ERROR*} $synth_status]}]

if {!$route_only || !$synth_done} {
    reset_run synth_1
    launch_runs synth_1 -jobs $jobs
    wait_on_run synth_1
    set synth_status [get_property STATUS [get_runs synth_1]]
}
puts "SYNTH_STATUS=$synth_status"

set changed [check_snapshot $snap_file]
if {[llength $changed]} {
    puts "SNAPSHOT_STATUS=CHANGED:[join $changed {,}]"
    error "源码在构建期间被改动，需重跑：$changed"
}
puts "SNAPSHOT_STATUS=ok"

if {![string match {*Complete*} $synth_status] || [string match {*ERROR*} $synth_status]} {
    set log [file join $proj_dir acx750.runs synth_1 runme.log]
    if {[file exists $log]} {
        puts "----- synth runme.log 末尾（原样） -----"
        set fd [open $log r]; set lines [split [read $fd] "\n"]; close $fd
        set n [llength $lines]
        for {set i [expr {$n-40>0?$n-40:0}]} {$i < $n} {incr i} { puts "LOG: [lindex $lines $i]" }
    }
    error "Synthesis failed: $synth_status"
}

#----------------------------------------------------------------------------
# 综合容量预检（先便宜地挡掉超容，再花时间做实现）
#   注意：最终以实现的整芯片 DRC 为准
#----------------------------------------------------------------------------
open_run synth_1
report_utilization -hierarchical -file [file join $build_dir synthesis_hierarchy.rpt]
report_timing_summary -file [file join $build_dir synthesis_timing.rpt]
set usage [report_utilization -return_string]
set lut_count -1
if {[regexp {\|[[:space:]]*Slice LUTs\*?[[:space:]]*\|[[:space:]]*([0-9]+)} $usage -> lut]} { set lut_count $lut }
set ff_count  [llength [get_cells -hier -filter {REF_NAME =~ FD*}]]
set bram36    [llength [get_cells -hier -filter {REF_NAME =~ RAMB36*}]]
set bram18    [llength [get_cells -hier -filter {REF_NAME =~ RAMB18*}]]
set dsp_count [llength [get_cells -hier -filter {REF_NAME =~ DSP48*}]]
set bram_eq   [expr {2*$bram36 + $bram18}]
puts "RESOURCE_GATE LUT=$lut_count FF=$ff_count BRAM36=$bram36 BRAM18=$bram18 DSP=$dsp_count BRAM_EQ=$bram_eq"
if {$lut_count > $GATE_LUT || $ff_count > $GATE_FF || $bram_eq > $GATE_BRAM || $dsp_count > $GATE_DSP} {
    puts "BIT_SKIPPED: 综合资源超 XC7A200T 门限，跳过实现"
    close_design
    close_project
    return
}
close_design

#----------------------------------------------------------------------------
# 实现到布线
#----------------------------------------------------------------------------
reset_run impl_1
launch_runs impl_1 -to_step route_design -jobs $jobs
wait_on_run impl_1
set route_status [get_property STATUS [get_runs impl_1]]
puts "ROUTE_STATUS=$route_status"
if {![string match {*Complete*} $route_status] || [string match {*ERROR*} $route_status]} {
    set log [file join $proj_dir acx750.runs impl_1 runme.log]
    if {[file exists $log]} {
        puts "----- impl runme.log 末尾（原样） -----"
        set fd [open $log r]; set lines [split [read $fd] "\n"]; close $fd
        set n [llength $lines]
        for {set i [expr {$n-40>0?$n-40:0}]} {$i < $n} {incr i} { puts "LOG: [lindex $lines $i]" }
    }
    error "Implementation failed: $route_status"
}

#----------------------------------------------------------------------------
# 时序 / DRC 门限
#----------------------------------------------------------------------------
open_run impl_1
report_timing_summary -file [file join $build_dir routed_timing.rpt]
report_drc            -file [file join $build_dir routed_drc.rpt]
report_utilization    -file [file join $build_dir routed_utilization.rpt]

set setup [get_timing_paths -max_paths 1 -setup]
set hold  [get_timing_paths -max_paths 1 -hold]
set wns [expr {[llength $setup] ? [get_property SLACK [lindex $setup 0]] : -999.0}]
set whs [expr {[llength $hold]  ? [get_property SLACK [lindex $hold  0]] : -999.0}]
set bad [get_drc_violations -quiet -filter {SEVERITY == Error || SEVERITY == {Critical Warning}}]
puts "ROUTED_WNS=$wns ROUTED_WHS=$whs DRC_BAD=[llength $bad]"

# 失败时打印路径详情（哪个时钟、哪条路径、slack 多少），不只给一个数字
proc print_path_detail {paths mode} {
    if {![llength $paths]} { puts "  $mode: 无路径"; return }
    set p [lindex $paths 0]
    set sp [get_property STARTPOINT_PIN $p]
    set ep [get_property ENDPOINT_PIN $p]
    set sl [get_property SLACK $p]
    set sc [get_clocks -quiet -of_objects [get_pins -quiet $sp]]
    set ec [get_clocks -quiet -of_objects [get_pins -quiet $ep]]
    puts "  $mode 最差路径: slack=$sl"
    puts "    start=$sp  clk=[expr {[llength $sc]?[get_property NAME [lindex $sc 0]]:{-}}]"
    puts "    end  =$ep  clk=[expr {[llength $ec]?[get_property NAME [lindex $ec 0]]:{-}}]"
}
set gate_fail 0
if {$wns < 0} {
    puts "GATE_FAIL: 建立时间 WNS=$wns < 0"
    print_path_detail $setup setup
    set gate_fail 1
}
if {$whs < 0} {
    puts "GATE_FAIL: 保持时间 WHS=$whs < 0"
    print_path_detail $hold hold
    set gate_fail 1
}
if {[llength $bad] != 0} {
    puts "GATE_FAIL: DRC 严重错误 [llength $bad] 条"
    foreach v [lrange $bad 0 [expr {[llength $bad]>5?4:[llength $bad]-1}]] {
        puts "  DRC: [get_property DESCRIPTION $v]"
    }
    set gate_fail 1
}
if {$gate_fail} {
    puts "BIT_SKIPPED: 时序或 DRC 门限未通过（详见 $build_dir/routed_timing.rpt、routed_drc.rpt）"
    close_design
    close_project
    return
}

#----------------------------------------------------------------------------
# 出 bit
#----------------------------------------------------------------------------
close_design
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
set bit_status [get_property STATUS [get_runs impl_1]]
puts "BIT_RUN_STATUS=$bit_status"
if {![string match {*Complete*} $bit_status] || [string match {*ERROR*} $bit_status]} {
    error "write_bitstream 步骤失败: $bit_status"
}

set run_bit [file join $proj_dir acx750.runs impl_1 acx750_top.bit]
if {![file exists $run_bit]} { error "运行目录下 bit 不存在: $run_bit" }
set bit [file join $out_dir acx750_top.bit]
file copy -force $run_bit $bit

open_run impl_1
write_hw_platform -fixed -include_bit -force -file [file join $out_dir acx750_top.xsa]
puts "BIT_READY=$bit"
close_project