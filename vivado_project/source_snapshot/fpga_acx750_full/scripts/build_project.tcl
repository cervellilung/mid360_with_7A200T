#============================================================================
# build_project.tcl -- ACX750 (XC7A200T-FBG484-2) 工程创建脚本
#
# 用法（Vivado 2018.3，batch 模式）：
#   vivado.bat -mode batch -source scripts/build_project.tcl
#   vivado.bat -mode batch -source scripts/build_project.tcl -tclargs -jobs 8
#   vivado.bat -mode batch -source scripts/build_project.tcl -tclargs -no_synth
#     （-no_synth 只做"建工程 + IP 生成 + 源文件归纳 + 快照"，不跑综合，
#       用于在 rtl/ 还在并行编写、暂时无法综合时快速自检）
#
# 本脚本职责：
#   1) create_project（用 -part，不用 -board；这块板不一定有 board part）
#   2) 递归收集 rtl/**/*.sv、*.v（.svh 只作 include 路径），排除 tb/tests/sim
#   3) 把 ip/ 下除 pll.xci 外的厂商 IP 当源码加入
#   4) 现场 create_ip 生成 clk_sys_wiz 并校验端口名
#   5) 加 constraints/*.xdc，设顶层 $TOP（默认 acx750_full_top），设策略
#   6) 综合前落盘"源码快照"（路径+mtime+size），综合后校验未被改动
#   7) 跑 synth_design，打印 SYNTH_STATUS / RESOURCE_GATE / 空匹配端口
#
# 判定标记（供 run_vivado.ps1 与人工读取）：
#   IP_PORTS_OK=...       clk_sys_wiz 实际端口列表
#   SYNTH_STATUS=...      综合运行状态
#   RESOURCE_GATE=...     综合后资源占用（仅参考，硬门限在 build_image.tcl）
#   EMPTY_PORT_MATCH=...  xdc 里 get_ports 匹配为空的端口（上板前必须为 None）
#   SNAPSHOT_STATUS=...   ok / CHANGED:<file>
#============================================================================

#----------------------------------------------------------------------------
# 顶层名（集中在此，换顶层只改这一处；命令行可用 -top 覆盖）
#----------------------------------------------------------------------------
set TOP       acx750_full_top

#----------------------------------------------------------------------------
# 路径推导：全部由脚本自身位置反推，禁止硬编码绝对路径
#----------------------------------------------------------------------------
set root      [file normalize [file join [file dirname [info script]] ..]]
set build_dir [file join $root build]
set proj_dir  [file join $build_dir acx750_full]
set xpr       [file join $proj_dir acx750_full.xpr]
set out_dir   [file join $root output]
file mkdir $build_dir
file mkdir $out_dir

#----------------------------------------------------------------------------
# 参数解析
#----------------------------------------------------------------------------
set do_synth  1
set jobs      10
for {set i 0} {$i < [llength $argv]} {incr i} {
    set a [lindex $argv $i]
    switch -- $a {
        -no_synth { set do_synth 0 }
        -jobs     { incr i; set jobs [lindex $argv $i] }
        -top      { incr i; set TOP [lindex $argv $i] }
    }
}
set_param general.maxThreads $jobs
puts "INFO: root=$root"
puts "INFO: TOP=$TOP"
puts "INFO: jobs=$jobs do_synth=$do_synth"

#----------------------------------------------------------------------------
# 递归收集源文件（自适应，不写死文件名）
#   - 目录名含 tb/tests/sim 的整棵子树跳过
#   - 文件名以 _tb.v 结尾的跳过
#   - .svh 单独收集，只作 include 路径，不作为源文件加入
#----------------------------------------------------------------------------
proc collect_sources {dir} {
    global rtl_files svh_files
    foreach entry [glob -nocomplain -directory $dir *] {
        set tail [file tail $entry]
        if {[file isdirectory $entry]} {
            set low [string tolower $tail]
            if {[string match *tb* $low] || [string match *tests* $low] || [string match *sim* $low]} {
                puts "SKIP_DIR: $entry"
                continue
            }
            collect_sources $entry
        } elseif {[file isfile $entry]} {
            set low  [string tolower $tail]
            set ext  [string tolower [file extension $entry]]
            if {[string match *_tb.v $low] || [string match *_tb.sv $low]} {
                puts "SKIP_TB_FILE: $entry"
                continue
            }
            switch -- $ext {
                .sv  { lappend rtl_files  $entry }
                .v   { lappend rtl_files  $entry }
                .svh { lappend svh_files  $entry }
            }
        }
    }
}

set rtl_root [file join $root rtl]
set rtl_files {}
set svh_files {}
collect_sources $rtl_root

puts "INFO: RTL 源文件 [llength $rtl_files] 个:"
foreach f [lsort $rtl_files] { puts "  SRC: [string map [list $root {}] $f]" }
puts "INFO: 头文件(.svh) [llength $svh_files] 个（作为 include 路径）:"
foreach f $svh_files { puts "  INC: $f" }

#----------------------------------------------------------------------------
# 建工程（-part，不是 -board）
#----------------------------------------------------------------------------
if {[file exists $xpr]} {
    # 已存在则复用以省时间；策略/源文件会在下面重新对齐
    open_project $xpr
    puts "INFO: 复用已有工程 $xpr"
} else {
    create_project -force -part xc7a200tfbg484-2 acx750_full $proj_dir
    puts "INFO: 新建工程 $xpr"
}

#----------------------------------------------------------------------------
# 加源文件
#----------------------------------------------------------------------------
foreach f $rtl_files {
    if {![llength [get_files -quiet $f]]} {
        add_files -norecurse $f
    }
}

# include 路径：rtl/（acx750_defs.svh）+ 每个 .svh 所在目录
#             + vendor_ref/display（disp_driver.v 里 `include "disp_parameter_cfg.v"）
set inc_dirs {}
lappend inc_dirs $rtl_root
foreach f $svh_files { lappend inc_dirs [file dirname $f] }
set disp_dir [file join $rtl_root vendor_ref display]
if {[file isdirectory $disp_dir]} { lappend inc_dirs $disp_dir }
set inc_dirs [lsort -unique $inc_dirs]
set_property include_dirs $inc_dirs [get_filesets sources_1]
puts "INFO: include_dirs = $inc_dirs"

# 顶层
set_property top $TOP [get_filesets sources_1]

#----------------------------------------------------------------------------
# 加厂商 IP（ip/*.xci，排除 pll.xci —— 顶层用自己的 clk_sys_wiz）
#
# 注意：Vivado 2018.3 里若多个 xci 放在同一个目录，会被判为 "Shared output
# directory" 而 locked，导致 OOC 综合报 "module ... not found"。因此这里把每个
# xci 复制到 build/vendor_ip/<ip> 各自独立目录后再加入（不改动 ip/ 原文件），
# 并为它们生成输出产物。
#----------------------------------------------------------------------------
set vendor_ip_dir [file join $build_dir vendor_ip]
file mkdir $vendor_ip_dir
set vendor_ips {}

# MIG 的配置存放在 xci 同目录的 mig_a.prj / mig_b.prj 里（xci 的
# PARAM_VALUE.XML_INPUT_FILE=mig_b.prj）；ip/ 里目前只放了 xci，缺这两个 prj 时
# MIG 会报 "Unconfigured MIG instance" 而无法生成。这里 best-effort：
#   1) 先找 ip/ 下的 prj（正解，用户把 prj 放进 ip/ 即可）
#   2) 否则在仓库上一级(FPGA 根)下按厂商例程的相对路径搜一遍（用通配符避免中文
#      目录名字面量，因为 Vivado 的 Tcl 读脚本时中文会被编码破坏）
#   把找到的 prj 复制到 build/vendor_ip/mig_7series_0/（仍然不动 ip/）。
proc find_vendor_mig_dir {root} {
    set fpga [file normalize [file join $root ../..]]
    set hit [glob -nocomplain [file join $fpga * ch57_* ch57_* eth_udp_rgmii_ddr3_tft800x480_32* * sources_1 ip mig_7series_0 mig_b.prj]]
    if {[llength $hit]} { return [file dirname [lindex $hit 0]] }
    return ""
}

foreach xci [lsort [glob -nocomplain [file join $root ip *.xci]]] {
    set name [file rootname [file tail $xci]]
    if {$name eq "pll"} {
        puts "SKIP_IP: $xci (pll.xci 不使用，顶层用 clk_sys_wiz)"
        continue
    }
    set dst_dir [file join $vendor_ip_dir $name]
    file mkdir $dst_dir
    set dst [file join $dst_dir [file tail $xci]]
    file copy -force $xci $dst
    if {![llength [get_files -quiet $dst]]} {
        add_files -norecurse $dst
    }
    lappend vendor_ips [get_ips $name]
    puts "ADD_IP: $xci -> $dst"

    # MIG 需要随附的 prj / xmdf 等辅助文件
    if {$name eq "mig_7series_0"} {
        set vend_dir ""
        if {![file exists [file join $root ip mig_b.prj]]} {
            set vend_dir [find_vendor_mig_dir $root]
        }
        if {$vend_dir ne ""} {
            puts "MIG_VENDOR_DIR=$vend_dir"
            foreach f [glob -nocomplain [file join $vend_dir *]] {
                if {[file isdirectory $f]} { continue }
                if {[file exists [file join $dst_dir [file tail $f]]]} { continue }
                file copy -force $f [file join $dst_dir [file tail $f]]
                puts "MIG_AUX_COPY: [file tail $f]"
            }
        } elseif {![file exists [file join $dst_dir mig_b.prj]]} {
            puts "MIG_AUX_MISSING: 缺少 mig_a.prj/mig_b.prj（请放入 ip/），MIG 将无法生成"
        }
    }
}

# 生成厂商 IP 输出产物（否则其 OOC 综合找不到 module，synth_1 会停住）
# 逐个 catch：单个 IP 生成失败也继续，把失败原样打出来
puts "INFO: 为厂商 IP 生成输出产物 ..."
foreach ip $vendor_ips {
    set n [get_property NAME $ip]
    if {[catch {generate_target all $ip} msg]} {
        puts "IP_GEN_FAILED=$n: $msg"
    } else {
        puts "IP_GEN_OK=$n"
    }
}

#----------------------------------------------------------------------------
# 现场生成 clk_sys_wiz（不手写 xci）
#   输入 50MHz 单端；4 路输出 200/100/33/24 MHz；低有效复位口名 resetn；带 locked
#   顶层例化端口固定为：clk_in1, resetn, clk_out1..4, locked
#----------------------------------------------------------------------------
set ip_gen_dir [file join $build_dir ip]
file mkdir $ip_gen_dir

if {![llength [get_ips -quiet clk_sys_wiz]]} {
    create_ip -name clk_wiz -vendor xilinx.com -library ip -version 6.0 \
        -module_name clk_sys_wiz -dir $ip_gen_dir
    puts "INFO: create_ip clk_sys_wiz 完成"
} else {
    puts "INFO: clk_sys_wiz 已存在，重新配置"
}

set_property -dict [list \
    CONFIG.PRIMITIVE                 {MMCM} \
    CONFIG.PRIM_IN_FREQ              {50.000} \
    CONFIG.PRIM_SOURCE               {Single_ended_clock_capable_pin} \
    CONFIG.NUM_OUT_CLKS              {4} \
    CONFIG.CLKOUT1_USED              {true} \
    CONFIG.CLKOUT2_USED              {true} \
    CONFIG.CLKOUT3_USED              {true} \
    CONFIG.CLKOUT4_USED              {true} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {200.000} \
    CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {100.000} \
    CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {33.000} \
    CONFIG.CLKOUT4_REQUESTED_OUT_FREQ {24.000} \
    CONFIG.USE_LOCKED                {true} \
    CONFIG.USE_RESET                 {true} \
    CONFIG.RESET_TYPE                {ACTIVE_LOW} \
    CONFIG.RESET_PORT                {resetn} \
] [get_ips clk_sys_wiz]

generate_target {instantiation_template synthesis simulation} [get_ips clk_sys_wiz]
puts "INFO: clk_sys_wiz generate_target 完成"

# ---------------------------------------------------------------------------
# 端口名校验：优先读生成物里的模块声明，若找不到再退化为读 .veo
# ---------------------------------------------------------------------------
proc find_file_recursive {dir name} {
    foreach entry [glob -nocomplain -directory $dir *] {
        if {[file isdirectory $entry]} {
            set hit [find_file_recursive $entry $name]
            if {$hit ne ""} { return $hit }
        } elseif {[file tail $entry] eq $name} {
            return $entry
        }
    }
    return ""
}

proc extract_ip_ports {ip_obj} {
    global ip_gen_dir
    set ip_name [get_property NAME $ip_obj]
    set ip_dir  [get_property IP_DIR $ip_obj]
    # 端口声明在生成物 <ip_dir>/<name>/<name>.v（或 .veo）；IP_DIR 可能指向父目录，
    # 因此对 IP_DIR 与生成目录都做递归查找
    set candidates {}
    foreach base [list $ip_dir $ip_gen_dir] {
        if {$base ne "" && [file isdirectory $base]} {
            foreach fname [list ${ip_name}.v ${ip_name}.veo ${ip_name}_stub.v] {
                set hit [find_file_recursive $base $fname]
                if {$hit ne "" && [lsearch -exact $candidates $hit] < 0} { lappend candidates $hit }
            }
        }
    }
    foreach f $candidates {
        set fd [open $f r]; set data [read $fd]; close $fd
        # 匹配： module <name> ( <port 列表> ) ;
        # 注意：Vivado 2018.3 的 Tcl 正则不支持 \b，这里不要用词边界
        if {[regexp -nocase "module\\s+${ip_name}\\s*\\((\[^)\]*)\\)\\s*;" $data -> plist]} {
            set ports {}
            # 端口列表按逗号切分，每段去掉方向/位宽/类型，只留末尾标识符
            foreach chunk [split $plist ","] {
                set chunk [string trim [string map {"\n" " " "\r" " "} $chunk]]
                if {[regexp {([A-Za-z_][A-Za-z0-9_]*)\s*$} $chunk -> pid]} {
                    lappend ports $pid
                }
            }
            return [list $f $ports]
        }
    }
    return [list "" {}]
}

set ip_res [extract_ip_ports [get_ips clk_sys_wiz]]
set ip_file [lindex $ip_res 0]
set ip_ports [lsort -unique [lindex $ip_res 1]]
puts "IP_PORTS_SOURCE=$ip_file"
puts "IP_PORTS=[join $ip_ports { }]"

set expect_ports {clk_in1 resetn clk_out1 clk_out2 clk_out3 clk_out4 locked}
set missing {}
foreach p $expect_ports {
    if {[lsearch -exact $ip_ports $p] < 0} { lappend missing $p }
}
if {[llength $missing]} {
    puts "IP_PORTS_OK=NO missing=[join $missing { }]"
    error "clk_sys_wiz 端口名与顶层例化不匹配，缺少: $missing（实际: $ip_ports）"
} else {
    puts "IP_PORTS_OK=YES"
}

#----------------------------------------------------------------------------
# 加约束
#----------------------------------------------------------------------------
set xdc_files [lsort [glob -nocomplain [file join $root constraints *.xdc]]]
foreach xdc $xdc_files {
    if {![llength [get_files -quiet $xdc]]} {
        add_files -fileset constrs_1 -norecurse $xdc
        puts "ADD_XDC: $xdc"
    }
}

#----------------------------------------------------------------------------
# 策略（写明并打印）
#----------------------------------------------------------------------------
set synth_strategy "Vivado Synthesis Defaults"
set impl_strategy  "Performance_ExplorePostRoutePhysOpt"
set_property strategy $synth_strategy [get_runs synth_1]
set_property strategy $impl_strategy  [get_runs impl_1]
puts "SYNTH_STRATEGY=$synth_strategy"
puts "IMPL_STRATEGY=$impl_strategy"

update_compile_order -fileset sources_1

#----------------------------------------------------------------------------
# 源码快照守卫：综合前记录（路径+mtime+size）到 build/ 下
#   只快照用户源文件（RTL + XDC），不含生成物，避免 IP 生成造成误报
#----------------------------------------------------------------------------
set snap_file [file join $build_dir source_snapshot.txt]
proc write_snapshot {snap_file files} {
    set fd [open $snap_file w]
    foreach f [lsort $files] {
        if {[file isfile $f]} {
            puts $fd "[file normalize $f]\t[file mtime $f]\t[file size $f]"
        }
    }
    close $fd
}
proc check_snapshot {snap_file} {
    set changed {}
    set fd [open $snap_file r]; set lines [split [read $fd] "\n"]; close $fd
    foreach line $lines {
        if {[string trim $line] eq ""} { continue }
        lassign [split $line "\t"] p mt sz
        if {![file isfile $p]} { lappend changed "$p(removed)"; continue }
        if {[file mtime $p] != $mt || [file size $p] != $sz} { lappend changed $p }
    }
    return $changed
}

set snapshot_targets [concat $rtl_files $svh_files $xdc_files]
write_snapshot $snap_file $snapshot_targets
puts "SNAPSHOT_WRITTEN=$snap_file ([llength $snapshot_targets] files)"

if {!$do_synth} {
    puts "SYNTH_STATUS=SKIPPED(-no_synth)"
    puts "PROJECT_STATUS=OK(no_synth)"
    close_project
    return
}

#----------------------------------------------------------------------------
# 综合
#----------------------------------------------------------------------------
reset_run synth_1
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
set status [get_property STATUS [get_runs synth_1]]
puts "SYNTH_STATUS=$status"

# 综合前记录的快照，综合后校验
set changed [check_snapshot $snap_file]
if {[llength $changed]} {
    puts "SNAPSHOT_STATUS=CHANGED:[join $changed {,}]"
    error "源码在综合期间被改动，需重跑：$changed"
} else {
    puts "SNAPSHOT_STATUS=ok"
}

if {![string match {*Complete*} $status] || [string match {*ERROR*} $status]} {
    # 把综合日志尾部原样打印，便于看到 RTL 语法错误（不改 RTL，只报告）
    set log [file join $proj_dir acx750_full.runs synth_1 runme.log]
    if {[file exists $log]} {
        puts "----- runme.log 末尾 60 行（原样） -----"
        set fd [open $log r]; set lines [split [read $fd] "\n"]; close $fd
        set n [llength $lines]
        for {set i [expr {$n-60>0?$n-60:0}]} {$i < $n} {incr i} { puts "LOG: [lindex $lines $i]" }
    }
    puts "PROJECT_STATUS=FAILED(synth)"
    error "Synthesis failed: $status"
}

#----------------------------------------------------------------------------
# 综合后：资源参考 + xdc 空匹配端口检查
#----------------------------------------------------------------------------
open_run synth_1
report_utilization -hierarchical -file [file join $build_dir synthesis_hierarchy.rpt]
report_timing_summary -file [file join $build_dir synthesis_timing.rpt]

set usage [report_utilization -return_string]
set lut_count -1
if {[regexp {\|[[:space:]]*Slice LUTs\*?[[:space:]]*\|[[:space:]]*([0-9]+)} $usage -> lut]} { set lut_count $lut }
set ff_count   [llength [get_cells -hier -filter {REF_NAME =~ FD*}]]
set bram36     [llength [get_cells -hier -filter {REF_NAME =~ RAMB36*}]]
set bram18     [llength [get_cells -hier -filter {REF_NAME =~ RAMB18*}]]
set dsp_count  [llength [get_cells -hier -filter {REF_NAME =~ DSP48*}]]
puts "RESOURCE_GATE LUT=$lut_count FF=$ff_count BRAM36=$bram36 BRAM18=$bram18 DSP=$dsp_count (2*BRAM36+BRAM18=[expr {2*$bram36+$bram18}])"

# 说明：这里不用花括号引用正则（字符类里的 `}` 会破坏 Tcl 花括号配对），
#       改成简单字符串扫描，避免转义陷阱。
proc xdc_port_patterns {xdc} {
    set fd [open $xdc r]; set data [read $fd]; close $fd
    set pats {}
    foreach raw [split $data "\n"] {
        set line [string trim $raw]
        if {$line eq "" || [string match "#*" $line]} { continue }
        while {[set pos [string first "get_ports" $line]] >= 0} {
            set rest [string trim [string range $line [expr {$pos + 9}] end]]
            if {[string index $rest 0] eq "\{"} {
                set close [string first "\}" $rest]
                if {$close > 0} { lappend pats [string range $rest 1 [expr {$close - 1}]] }
            } elseif {[regexp {^([A-Za-z0-9_]+)} $rest -> p]} {
                lappend pats $p
            }
            set line [string range $line [expr {$pos + 9}] end]
        }
    }
    return $pats
}
set empty_hits {}
foreach xdc $xdc_files {
    foreach pat [xdc_port_patterns $xdc] {
        if {[llength [get_ports -quiet $pat]] == 0} {
            lappend empty_hits "[file tail $xdc]:$pat"
        }
    }
}
if {[llength $empty_hits]} {
    puts "EMPTY_PORT_MATCH=[join $empty_hits { }]"
    puts "WARNING: 以上 get_ports 在 RTL 顶层找不到对应端口（未做 -no_assert 掩盖）"
} else {
    puts "EMPTY_PORT_MATCH=None"
}
close_design

puts "PROJECT_STATUS=OK"
puts "INFO: 工程已就绪：$xpr"
close_project