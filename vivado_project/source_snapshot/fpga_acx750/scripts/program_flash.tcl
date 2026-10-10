#============================================================================
# program_flash.tcl -- 把 bit 转成 .bin 并烧写到板载 QSPI Flash（掉电保留）
#
# 用法（Vivado 2018.3，batch 模式）：
#   vivado.bat -mode batch -source scripts/program_flash.tcl
#   vivado.bat -mode batch -source scripts/program_flash.tcl -tclargs -bit output/acx750_top.bit
#
# Flash：MX25L12835F，16 MB（128 Mbit），SPIx4
# 判定标记：FLASH_BIN=<path> / FLASH_STATUS=OK / FLASH_STATUS=FAILED:<原因>
#============================================================================

set root    [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $root output]
set bit     [file join $out_dir acx750_top.bit]
set bin     [file join $out_dir acx750_top.bin]

#----------------------------------------------------------------------------
# 参数：-bit <path> 覆盖默认 bit 路径（-bin <path> 覆盖输出 bin）
#----------------------------------------------------------------------------
for {set i 0} {$i < [llength $argv]} {incr i} {
    set a [lindex $argv $i]
    switch -- $a {
        -bit { incr i; set bit [lindex $argv $i] }
        -bin { incr i; set bin [lindex $argv $i] }
    }
}
set bit [file normalize $bit]
set bin [file normalize $bin]
if {![file exists $bit]} {
    puts "FLASH_STATUS=FAILED:bit 不存在 $bit"
    error "bit 文件不存在: $bit"
}
file mkdir [file dirname $bin]

#----------------------------------------------------------------------------
# bit -> bin（SPIx4，16MB，从 0 地址起）
#----------------------------------------------------------------------------
write_cfgmem -format BIN -interface SPIx4 -size 16 \
    -loadbit "up 0x0 $bit" -force $bin
puts "FLASH_BIN=$bin"

#----------------------------------------------------------------------------
# 烧写到 QSPI
#----------------------------------------------------------------------------
if {[llength [info commands open_hw_manager]]} {
    open_hw_manager
} else {
    open_hw
}
connect_hw_server
open_hw_target

set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

# cfgmem 器件型号：MX25L12835F 对应的 Vivado part 名
set part_name "mx25l12835f-spi-x1_x2_x4"
set parts [get_cfgmem_parts -quiet $part_name]
if {![llength $parts]} {
    puts "FLASH_STATUS=FAILED:找不到 flash part $part_name（可用 get_cfgmem_parts 查）"
    error "未找到 cfgmem part: $part_name"
}
create_hw_cfgmem -hw_device $dev [lindex $parts 0]
set cfgmem [lindex [get_hw_cfgmems] 0]

set_property PROGRAM.BLANK_CHECK   0 $cfgmem
set_property PROGRAM.ERASE         1 $cfgmem
set_property PROGRAM.CFG_PROGRAM   1 $cfgmem
set_property PROGRAM.VERIFY        1 $cfgmem
set_property PROGRAM.CHECKSUM      0 $cfgmem
set_property PROGRAM.ADDRESS_RANGE {use_file} $cfgmem
set_property PROGRAM.FILES         [list $bin] $cfgmem
set_property PROGRAM.PRM_FILE      {} $cfgmem
set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none} $cfgmem

program_hw_cfgmem -hw_cfgmem $cfgmem
refresh_hw_device $dev

puts "FLASH_STATUS=OK device=$dev bin=$bin"