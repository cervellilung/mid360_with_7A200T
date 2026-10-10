#============================================================================
# jtag_program.tcl -- 通过 JTAG 下载 bit 到 ACX750（易失性，掉电丢失）
#
# 用法（Vivado 2018.3，batch 模式）：
#   vivado.bat -mode batch -source scripts/jtag_program.tcl
#   vivado.bat -mode batch -source scripts/jtag_program.tcl -tclargs -bit output/acx750_top.bit
#   vivado.bat -mode batch -source scripts/jtag_program.tcl -tclargs -bit D:/x/acx750_top.bit
#
# 判定标记：JTAG_STATUS=OK / FAILED:<原因>
#============================================================================

set root    [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $root output]
set bit     [file join $out_dir acx750_top.bit]

#----------------------------------------------------------------------------
# 参数：-bit <path> 覆盖默认 bit 路径
#----------------------------------------------------------------------------
for {set i 0} {$i < [llength $argv]} {incr i} {
    set a [lindex $argv $i]
    switch -- $a {
        -bit { incr i; set bit [lindex $argv $i] }
    }
}
set bit [file normalize $bit]
puts "INFO: PROGRAM.FILE=$bit"
if {![file exists $bit]} {
    puts "JTAG_STATUS=FAILED:bit 不存在 $bit"
    error "bit 文件不存在: $bit"
}

#----------------------------------------------------------------------------
# 硬件管理器：2018.3 用 open_hw；较新版本（2020.2+）改用 open_hw_manager
#   这里做兼容：存在 open_hw 优先用它
#----------------------------------------------------------------------------
if {[llength [info commands open_hw_manager]]} {
    open_hw_manager
    puts "INFO: 使用 open_hw_manager（新版命令）"
} else {
    open_hw
    puts "INFO: 使用 open_hw（2018.3 命令）"
}

connect_hw_server
open_hw_target

set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
refresh_hw_device $dev

puts "JTAG_STATUS=OK device=$dev bit=$bit"