## 2026-10-07 Full 视频延迟 HUD 与风险回归（当前结论）

修改只进入标准活动工程 `vivado_project/acx750_full/acx750_full.xpr`；通信版、旧工程、厂商原件未改。没有本轮硬件操作；已生成新的离线候选bit并通过现有时序/DRC门禁，但不是全CDC/外部IO预算或板级验收完成。

### 已完成代码与测量口径

- 新增 `imports/video/acx750_video_latency.sv`，在相机每帧第一个解码后的有效 RGB565 像素处捕获 48 位微秒时间戳和 16 位帧号，用连续 8 个像素携带双魔数、时间戳、帧号、异或校验与尾标记；这些字经过实际相机 FIFO/DDR 写读路径。输出端识别同一标记，计算首像素年龄，并将标记像素置黑，再进入普通显示/AR。异或校验不是 CRC。扫描匹配魔数可能短暂遮盖未完成匹配的候选像素；这不是完全无损视频测量。
- 板端 HUD 最后一行显示 `VID xxx.xxxMS V1`，无有效样本或 画面采集年龄达到 250 ms时显示 `VID ---.---MS V0`。这是“首个 RGB565 有效像素进入写路径→DDR 读出像素在显示时钟域被消费”的延迟；CAM 到 HDMI RGB 输出在同一拍，AR 额外一拍以保守 +1 us 计。数值不包含曝光、传感器内部读出、HDMI 外部链路和屏幕响应，也不是整帧最后像素完成时间。
- 现有 DDR 是连续环形读写，尚无完整帧银行所有权；本方法能追踪标记首像素，不能证明整帧无撕裂。切换显示模式后要等新标记；只有读完校验正确的 8 字标记才更新 HUD。
- 不增加视频流水寄存器或整帧缓存，不改变相机像素吞吐；串行十进制转换在 SYS 控制域运行 20 拍（100 MHz 下 0.20 us），只影响 HUD 更新。完整采集时间低32位随元数据跨域，控制域按采集年龄失效；重复旧标签或排队到达都不能刷新有效期。元数据使用 16×80 位 LUTRAM 异步 FIFO；满时丢弃测量，不反压视频，之后由有效期撤销旧值。它不是图像队列。
- 48 位时间基准在 S0 暖复位时保持单调，避免旧 DDR 标签被误认为新时间。XPM 2020.2 的 CDC_GRAY 最大 32 位，所以使用源端寄存的 48 位 Gray 总线、支持 48 位的 ARRAY_SINGLE 两级同步、目的域固定前缀 XOR 寄存解码。仿真检查 Gray 每次只变一位；新 implementation-only XDC 施加 10 ns bus_skew，审计 Tcl 逐域核对 48 个源和 48 个首级寄存器。该约束的最终布线结果仍须检查。
- 已有风险模型是有效原始点最近距离分级：危险门限以内为 2，警告门限以内为 1，否则 0；无目标时最近距离/风险为 0，AR 的数据年龄超过 150 ms 会撤框/显示无效。门限是参数，测试采用 500/2000 mm。未实现 TTC、刹车距离或自动底盘制动，不把无目标等同于整片空间已证实安全。

### 离线证据

所有 Vivado 调用经 `tools/run_build.py` 图形监视器，线程上限 20。

| 测试 | 结果及证据 |
|---|---|
| 标签/BCD/实际 HUD | PASS；正常和 AR +1 us、无效间隙、坏校验/未来/过大时间拒绝、48 位时间跨低 32 位进位、模式中止、过期撤销、HUD 文本。`results/full_video_latency_20261007/full_latency_capture_age.log` |
| 三异步时钟/XPM FIFO | PASS；测量误差在仿真参考 ±2 us，模式清空、复位后无旧样本恢复、新帧更新、重复读出采集年龄已过期的旧帧不得恢复 V1。`full_latency_capture_cdc.log`（有效期缩短为100 us加速相同状态逻辑的测试，默认部署250 ms）；用测试内存模拟视频延迟，不是板上 DDR/HDMI 测量 |
| 新模块 OOC 综合 | PASS；667 LUT、1107 FF、56 LUTRAM、0 BRAM、0 DSP；内部 setup WNS +4.072 ns，hold +0.127 ns。48 位 Gray 两个目的域全部覆盖；CDC 没有 Critical，Gray 数组和厂商异步 RAM 警告保留解释。不是 Full 路由签核。`final_ooc.log` 与 `synthesis/*.rpt` |
| Full 顶层展开 | PASS；新模块、HUD、清理像素与相机写路径接口均接入。`full_elaboration.log` |
| 同步投影/风险边界 | PASS；非零正负畸变对旧参考一致，500/501/2000/2001 mm 与空目标边界正确。`projector_risk.log` |
| Full AR 像素回归 | PASS；1,140,240 个非 HUD 像素零失配，延迟仍 L=1，三帧 SOF/EOL 数正确，无背压。`ar_wrap.log` |
| 实际 AR 风险/年龄 | PASS；3 种风险色、无视频输入时年龄继续增长并撤框、已经过期的发布不画框、空目标透传。`ar_risk_age.log` |

### 复位/BRAM 修复的新结论

`full_preserved_reset_preflight` 已完成 EXIT0（不是仍在运行）：38264 LUT、36168 FF、62 RAMB36、20 RAMB18、76 DSP、1398 control sets，综合 setup WNS +0.964 ns。这些数字是新增视频延迟模块之前的整机基线。两个小 reset 实例保留后，最大实际单网扇出从 9486 降到 4865；另一分组 4621，只增 1 LUT 和 2 FF。`all_fanout -endpoints_only` 为跨组合逻辑的传递端点数，不能作为单网扇出。

最新整机状态：修复后的 Full 整机 preflight 已通过：38926 LUT、37273 FF、62 RAMB36、20 RAMB18、76 DSP，setup WNS 0.964 ns，Critical Warning 0。日志 `results/full_video_latency_20261007/final_preflight.log`；不是路由/实板签核。

### 下一步与板上验收

1. （本轮已完成）读取最新 Full 综合资源/关键路径/CDC，运行 `audit_full_packet_fifo.tcl`。实际 packet FIFO 有 4 组 Gray 指针：10/11/10/11，总源/首级各 42 位；不能按 22 位假设判断失败。审计还加载新增延迟 bus_skew XDC，只修改内存中的审计设计，不保存项目/检查点。
2. （本轮已完成）综合门禁通过后用 `build_750.tcl acx750_full phys` 做一次有界布局/物理评估；核对 Slice、拥塞、单网扇出、Gray 约束与时序。先处理实际失败路径，不能反复直接 route。
3. （本轮候选构建已完成，相关CDC/IO预算仍待审）最终路由 WNS/WHS≥0、DRC/管脚门禁通过后再生成 bit、记录源码哈希并通知上电。原有 Full CDC-1/10/13、全局 clock_groups 覆盖 XPM max_delay（TIMING-24）、外部 IO 预算仍需审查，preflight 不能替代这些验证。
4. 临时 JTAG 上板：相机模式确认 `V1` 和更新频率；切换 AR 确认数值/框有效；遮断/停止视频后先确认控制域250 ms内失效，再确认字符HUD在最多再250 ms加显示帧相位后显示 `V0`，恢复后更新；S0 与模式切换不能出现未来/旧样本伪有效。与 ILA 或光学基准交叉验证误差，另外检查环形帧缓存撕裂。
5. 复测 Full 四类遥测连续性/暖复位、雷达 12 s 启动宽限、真实目标与底盘。最终安装位置未定，不能验收真实相机-雷达对齐。

专项审计已通过：42/42 位包 FIFO 指针按4组逐项匹配，两个独立复位同步器仍保留；新增时间戳 Gray 覆盖为48/48/48并使用10 ns bus_skew；包 FIFO 外来时钟直接驱动 D 引脚的 Critical 项为0。真实单网最大扇出仍4865；综合控制集1423。证据 `fifo_gray_audit.log` 与 `results/full_lut_integration_20261007/fifo_audit/`。综合的 bus_skew 估计不是布线后签核。

有界物理评估EXIT0：Slice47.97%、setup+0.502ns、最大逻辑单网扇出4865；拥塞报告未列出level5以上窗口，结构门禁PASS。相比10-06 Slice61.55%、level5/128%有实际改善。这是phys_opt_design阶段，不是路由后签核。已从完成的物理阶段继续单次route并生成候选bit，使用resume_full_route.py/Tcl复用既有门禁且不重复综合/布局；候选签名仍检查全部源文件/XCI哈希与新bit时间。

**最终候选：** `vivado_project/acx750_full/acx750_full.bit`；SHA256 `2a70d1576be577016cc01b74af7e3fe40b5e0f2f86e70eb19a9650058704b84e`。最终门禁 WNS=0.123 ns、WHS=0.036 ns、DRC_BAD=0，布线网络全部完成，route_design用时2分53秒；最终36846 LUT（27.37%）、36547 Slice Registers（其中36533 FF）、16047 Slice（47.69%）。日志route.log，routed_timing/routed_drc/monitor_routed_utilization.rpt在标准工程内。候选签名全部源码/约束/XCI匹配，board_verified=false；绝不能把candidate写成真设备通过。

布线后专项审计EXIT0：两个时间戳目的域各48位覆盖仍在，所有报告的bus_skew约束无VIOLATED，新增u_video_latency没有Critical CDC。原整机CDC-1=37、CDC-10=9、CDC-13=19仍待逐项审，不能据此声称整机CDC清零。证据routed_audit.log和routed_audit/{bus_skew,cdc}.rpt。

**现在下一步是板测，先不再编译。** 在根目录运行 `.venv\Scripts\python.exe -m web_server.full_board_test --mode preflight` 确认候选哈希/时序/DRC与已验证PHY/ARP来源。板卡当前按断电处理；确认接线与供电后只临时JTAG加载新bit，不写Flash。先S3看实景与VID，再短录30秒四类遥测/CRC/序号，再暖复位/断流/恢复测试；最终安装/标定与真实底盘仍未验证。

## 本轮接续：AC880 时序与控制集（2026-10-06）

- 用户最新停工线：仅看五小时额度，剩余40%时停止启动新工作并写交接；已经运行的 Vivado 任务保留。上次读取剩余55%。不消耗周额度作为门槛。snapshot目录和现有快照协议保持，旧工程及ACX750没有修改。
- 已完成 AR 当前源：左右眼加减移入已有入口级，再把距离BCD零值判断移入同一级，累计额外像素延迟仍10ns、连续吞吐1像素/拍。活动 ar_video.sv SHA256=4b6159bf4f61f34ecf079ab4d27e746d3c48fe3d353c42b9a9796cafabe48d0c。
- 两种HUD各425984像素与旧参考模型逐像素对拍通过，涵盖32目标、2048横向、63视差、负坐标、反向框、帧内过期、SOF、随机背压和暖复位。局部综合 EXIT0：6596 LUT/8025 FF/26控制集，像素最差+0.167ns；局部值不代表整机/布线。
- 整机任务ac880_integrated_font_flag_20261006及实际CDC 5ns/8ns约束值审计EXIT0：30757 LUT、40184 FF、66 BRAM36等效、73 DSP、1540控制集，综合WNS +0.021ns，WHS -0.100ns。最差路径active目标边界→ph0，6级且估计连线占68%。当前ac880_font_flag_place_20261006正在opt/place/phys_opt，日志vivado_project/logs/ac880_font_flag_place_20261006_status.log；等物理资源、Slice和WNS/WHS后再决定是否单次route。不能把综合转正当成路由通过。
- 配置控制集试验只在 results/ac880_cfg_ce_candidate_20261006 备好，活动 perception_regs_ram.sv 未变。候选只给shadow加EXTRACT_ENABLE=no，保留cfg、AXI/部分写/原子提交和快照；入口tools/scripts/test_ac880_cfg_ce_candidate_20261006.tcl。整机AR验收后才顺序运行该试验，先比较同设置 OOC 控制集、LUT/FF、时序，再考虑物理实现和合入。
- 未解决：最近已完成的年龄折叠版路由WNS -0.361ns、WHS +0.036ns，60096/60096可路由网布通、0routing errors；最新AR版本尚无布局/路由结果。旧版Slice92.67%/1497控制集，当前控制集是否下降尚需新物理报告。外部RGMII/TFT/UART IO时序缺口、组合复位CDC Critical 未签核，不生成可验收bit，不宣称上板成功。
- 若本轮到40%停工，最后补最新报告和问题分析。继续工作时先执行同步规则、读取任务状态、避开重跑已有结果。HDL源/XDC/Tcl写GBK无BOM，Markdown/Python写UTF8无BOM；HDL循环会展开硬件，每项修改记录实际FF/CE/BRAM、延迟、吞吐和时序，按仿真→综合→物理→板测逐级验收。

## AC880左右眼运算前移已激活，整机综合中（2026-10-06）

- 本轮停工线：五小时剩余50%，忽略周额度；停止启动新任务但不打断运行中的编译。snapshot、ACX750、厂商原件和旧工程未修改。
- 活动AR SHA256：b6714270dcde6addd62940fa3c34fa0d8fa550835c82cc1066f437886ed5777b。只把32目标左右眼横坐标加减移入已有入口级，下一拍比较；新增数据寄存器不reset，统一CE并随整条像素背压冻结。额外延迟保持10ns，吞吐保持1像素/拍，输入SOF快照提交及TTL时刻不改变。13位有符号覆盖-63到2110，不能缩为11位或把负坐标当无符号。
- 双HUD各425984像素对拍通过，含2048横向、63视差、负坐标、反向边界、随机背压、暖复位与临近TTL。局部6540 LUT/8026 FF/27控制集；相对上版局部多243 LUT/759 FF。最差变为字形选择，WNS -0.036ns；几何路径最差约+0.167ns。局部结果不能当整机路由结果。
- 原局部构建末尾puts因stdout通道丢失返回EXIT1，但仿真/综合/报告/DCP已完成，失败原日志保留。独立audit_ac880_eye_stage_20261006.tcl重新打开DCP、核对两项仿真PASS及768个实际眼坐标FF、实际5ns CDC约束，EXIT0。不是把失败状态手动改成功。
- CDC对象选择限定IS_SEQUENTIAL，避免名称匹配选中LUT无效起点；5ns/8ns约束值保持不变。活动回归fixture已更新，test_ac880_ar_pipeline.tcl输出独立results/ac880_ar_pipeline_regression，不覆盖历史对拍目录。
- 当前ac880_integrated_eye_stage_20261006，监视PID4816只作历史线索；状态日志vivado_project/logs/ac880_integrated_eye_stage_20261006_status.log。最终读取整机资源/时序/实际CDC覆盖，之后才决定place，再决定单次route。没有新bit，无新增硬件通过结论。
- 编码RTL/Tcl/XDC为GBK无BOM，Markdown/Python UTF8无BOM。HDL的for在这里实际展开32对加减器和寄存器，应先量化硬件并行代价、CE/control sets、位宽、latency和吞吐；禁止按软件代码简洁程度优化。

## AC880继续优化：本轮五小时剩余50%停工（2026-10-06）

- 本轮开始额度剩余99%，只看五小时窗口，剩余50%停止启动新任务并完成交接；已经运行的编译不打断。snapshot及其他工程保持不动。
- 已核验上轮ac880_age_fold_route_20261006最终EXIT1：60096/60096可路由网络全部布通、0routing errors；WNS -0.361ns、WHS +0.036ns。DRC只有Warning/Advisory；尚有外部I/O时序缺失和复位CDC待审核，未生成bit。
- 最差input_x/active目标坐标→ch0/rh0，8级含4个CARRY4。修复候选把两眼横坐标加减移到现有入口级，下一拍仅比较，不新增流水周期；预计新增832个无reset数据FF，统一CE，额外延迟仍10ns、吞吐1像素/拍。最终资源和Slice须实测，不能按估值签核。
- 候选及证据位于results/ac880_ar_eye_stage_20261006；仿真入口tools/scripts/test_synth_ac880_eye_stage_20261006.tcl，双HUD各425984像素，覆盖2048横向范围、63视差、负坐标、反向框、TTL、背压及暖复位。当前仍在验证，未激活候选。
- 后续顺序：局部仿真/综合→检查资源及路径→通过后再替换活动AR及同步回归fixture→整机综合和CDC约束值审计→物理优化→按结果决定单次route。禁止无依据重复长时间route或放松约束。

## 停工交接：五小时额度剩余3%（2026-10-06）

### 当前状态与有效版本

本次最后一次额度读取 usedPercent=97，低于剩余5%停工线。从此不启动新开发/测试/实现任务，保留已经启动的布线。最新活动工程是 vivado_project/ac880/ac880.xpr；活动AR SHA256：e89842000c0f7dc91dfa94d95279971b15ff0261fb49e7a30bc3c5472ac93fee。只改现行AC880，不动snapshot、旧工程、厂商原件或ACX750；未提交/推送Git，未下载、未烧录、未上板。

### 已完成

1. 修正XDC不支持if导致CDC约束跳过的问题。AR5ns、统计8ns在实际DCP的REQUIREMENT及exception coverage审计通过；不豁免整时钟域。统计64位源保持/请求应答快照及TFT内部时钟修复保留。
2. AR改为入口像素/坐标/有效标志寄存→每目标命中与字形寄存→目标归并/行列选择→颜色输出。额外2个200MHz周期，累计10ns；稳态1像素/拍。背压所有像素段冻结；每个像素保留输入接受时的live/motion_live，目标快照仍在输入SOF接受时提交。
3. 年龄有效期普通分支去掉加一→比较链，swap分支保持next_age语义，不增加延迟。支持的正整数VIDEO_HZ产生的门限小于UINT32_MAX，0门限显式失效。
4. 双HUD、32目标、持续输入、随机背压、暖复位、帧首标志、帧中途150ms/1s过期及逐拍live信号对拍通过。参考fixture仅仿真使用；可复现入口 tools/scripts/test_ac880_ar_pipeline.tcl。RTL/Tcl/XDC用GBK无BOM，MD/Python用UTF8无BOM。
5. 最终整机综合/审计EXIT0：30493 LUT、39426 FF、66 BRAM36等效、73 DSP、1541控制集；最终opt/place/phys_opt EXIT0：27714 LUT、36819 FF、Slice92.67%、1497控制集，WNS-0.086ns/TNS-0.646ns/15端点；WHS-0.233ns是路由前估值。

### 已启动但尚未验收

最后单次布线 ac880_age_fold_route_20261006 已启动，历史监控PID28588。不要凭PID认定仍在运行，先看 vivado_project/logs/ac880_age_fold_route_20261006_status.log。结果目录 results/ac880_age_fold_route_20261006。入口 tools/scripts/route_ac880_age_fold_20261006.tcl；只取布线报告，不会生成bit或上板。本交接时尚未将它判定为通过。

### 下一步，按顺序做

1. 额度恢复后先读本节、同步规则及当前任务日志，不重复综合。若status仍空，检查进程/日志最后阶段，保留运行中的编译。
2. 若任务完成，查看EXIT、timing.rpt、setup.rpt、hold.rpt、route_status.rpt、bus_skew.rpt、drc.rpt、methodology.rpt。WNS/WHS负会由脚本返回EXIT1但保留DCP/报告，不能把它当工具崩溃。
3. 若路由时序通过，核对所有可路由网络是否完整、skew及DRC，继续审核外部RGMII/TFT/UART IO时序契约与两项复位组合CDC Critical。审核完成才另行生成候选bit/XSA；当前没有新bit，没有新硬件通过结论。
4. 若仍负，优先按实际最差路径修改。可能方向：进一步拆分视差加法与边界比较，或预计算边界；先量化FF/Carry/控制集与延迟，独立对拍再进活动工程。高Slice92.67%仍需真实控制集/FF packing/跨模块选择网络审计，不能只看LUT52.09%。不要降低频率、滥用false/multicycle或反复换策略。

### 已排除与仍存问题

- 上一版route在约3分6秒完成，60839/60839可路由网络全部布通、routing errors=0、bus_skew MET、WHS+0.029ns，但WNS约-0.584ns；证明该次失败是setup负，不是无法布通或工具启动失败。无需重试旧5ns版本。
- 只加入staged快照曾增加宽MUX资源；帧首窄命中、字形预译码、tick换算与两级像素分割才有实测改善。不能重新引入holding直通异步像素比较、像素域十进制除法/年龄乘法、大型复位数组。
- 最终版未上板；真实底盘、USB相机/视频、PL雷达采集与ARM/Linux联调状态不能由本次仿真和实现覆盖。外部IO未约束和复位CDC尚未解决；详细历史和失败日志见LONG_RUNNING_ISSUES及04工程构建与优化。

### 以后写代码必须坚持

先把RTL、约束、工具设置与实现结果作为完整设计；按硬件结构审查位宽、同步RAM、端口、控制集、扇出与动态MUX。新增流水明确延迟/吞吐/帧边界/背压，datapath用valid控制避免机械reset。条件判断放普通Tcl，XDC只使用工具支持命令；必须验证实际约束值、覆盖与物理skew。PC/嵌入式循环执行与HDL硬件展开不同，不能按软件代码长度优化。先报告根因，最小修改、黄金对拍、局部综合、整机审计、物理实现再硬件验证，禁止拿局部结果替代全工程结论。

## AC880 本轮最终物理结果及布线验证（2026-10-06）

- 年龄折叠版布局/物理优化完整EXIT0：27714 LUT（52.09%）、36819 FF（34.60%）、Slice 12325/13300（92.67%）、66 BRAM36等效、73 DSP、1497控制集。
- WNS -0.086ns、TNS -0.646ns、15个setup失败端点；WHS -0.233ns、160个hold端点（路由前）。最差active目标边界→ch0；无level5以上拥塞。LUT改善并未解决Slice打包占用，不能仅按52%LUT判断余量充足。
- 启动最后单次ac880_age_fold_route_20261006，入口tools/scripts/route_ac880_age_fold_20261006.tcl。输出results/ac880_age_fold_route_20261006；状态日志vivado_project/logs/ac880_age_fold_route_20261006_status.log。只取route/status/timing/skew/DRC等，不含bit/JTAG。
- 本轮不再启动新的RTL方向。到五小时剩5%时停止新任务，已运行编译保持，由后续读取最终报告。下一步先看EXIT和WNS/WHS、全部网络是否路由、bus_skew、DRC；如仍负则审计具体目标比较与control-set packing，不重跑盲目策略。外部IO时序与复位CDC尚未签核，所有新功能未板测。
- 当前活动AR累计新增10ns、1像素/拍，四级同步像素pipeline；已验证原始像素/标志、连续吞吐、随机背压、暖复位、中途过期及逐拍live信号。snapshot没有修改；原版本与各候选证据在results下各独立目录，未推送Git。

## AC880 年龄比较版整机通过，正在布局（2026-10-06）

- ac880_integrated_age_fold_20261006 综合及实际CDC约束审计完整EXIT0；资源30493 LUT、39426 FF、63 RAMB36+6 RAMB18（66等效）、73 DSP、1541控制集。
- 整机WNS -0.178ns、TNS -1.686ns、20个setup端点，WHS -0.100ns。最差已回到输入坐标→红眼命中；年龄加一→live_q退出最差路径。局部收益不能直接相减当整机总数：局部少13LUT，整机重映射后比上一版多69LUT/2FF。
- 当前 ac880_age_fold_place_20261006（opt/place/phys_opt，不含route/bit），复用已审计DCP。结果results/ac880_age_fold_place_20261006，日志vivado_project/logs/ac880_age_fold_place_20261006_status.log。只改现行ac880，snapshot完全不动。
- 下一步读取最终Slice、拥塞、路径和bus_skew。改善且无严重拥塞时才做单次受控route，仍由路由后WNS/WHS/DRC等决定，不反复盲目跑策略。所有新RTL都未上板，无新bit。
- 编码GBK无BOM，文档UTF8；累计额外像素延迟10ns，稳态吞吐1像素/拍。支持的正整数VIDEO_HZ与计数门限范围要求见年龄折叠前一节；原golden仅仿真使用，不纳入活动综合。

## AC880 年龄比较去加法链已进入活动工程（2026-10-06）

- 入口寄存版整机综合/审计EXIT0：30424 LUT、39424 FF、66 BRAM36等效、73 DSP、1541控制集。最差从SOF/目标网络转为age→live_q，WNS-0.588ns、TNS-1.766ns、19端点，WHS-0.100ns。尚未布局，不将此值混同路由。
- 针对正常递增分支，(饱和age+1)<L 等价为 age<(L-1)，条件为支持的正整数VIDEO_HZ产生0<L<UINT32_MAX；L=0分支显式为false，MAX年龄两者均失效。swap分支仍比较next_age，motion对应处理。去掉递增→比较级联，不改变年龄计数本身和有效期时刻，不增加任何流水。
- 两种HUD各106496像素、随机背压、连续每拍一像素、暖复位、149998us/999998us中途过期对拍通过；同时逐拍核对live_q与motion_live_q。局部综合6297 LUT/7267 FF，WNS-0.032ns、TNS-0.032ns、1个setup端点，WHS+0.157ns。
- 已激活ar_video年龄折叠候选，累计像素延迟仍比原版多2周期/10ns。原入口版保存results/ac880_ar_age_fold_20261006/ar_video_active_before.sv；更新仿真TB保留黄金参考不变。
- 当前启动ac880_integrated_age_fold_20261006，先整机综合/实际CDC约束审计。完成后看资源与路径，再进入布局；当前没有该版本的整机结果、没有新bit、没有板测。上一版60839网络全路由但setup负的证据保持完整。
- 继续审核高Slice占用、外部IO时序及复位CDC；不改频率/精度、不放宽路径、不碰snapshot。五小时剩5%停止新任务并交接，周额度不管。

## AC880 实际布线取证及入口寄存版接入（2026-10-06）

- 上一版单次route约3分6秒完成，60839/60839可路由网络全部布通，routing errors=0；但WNS约-0.584ns、WHS+0.029ns，故脚本时序门槛返回EXIT1。这是时序不通过，不是工具崩溃或未布通。bus_skew全部MET，DRC无Error/无Critical（保留DSP流水警告等）；未生成bit。
- 实际最差x→ch0约-0.583ns；上游VDMA的SOF→ph0/rh0也在前列，布线占延迟约67%至74%。不继续换策略盲目route。
- 新入口寄存候选将SOF/像素/光栅坐标/字符位置/有效标志先锁存，再进入命中和字形选择。帧边界应答、参数提交和年龄更新仍在输入接受周期，几何计算使用该像素捕获的live/motion_live，避免中途过期语义改变。此后仍每拍1像素；累计多2个200MHz周期（10ns），不是新增一帧缓存。
- 两种HUD/32目标/106496像素的持续输入、随机背压、暖复位、SOF流式对拍通过；追加radar_age=149998us和motion_age=999998us的帧中途过期两项也全部EXIT0。新增datapath无reset，in_valid与各阶段valid控制有效性，阻塞时整条像素pipeline冻结。
- 局部综合EXIT0：6310 LUT/7267 FF，WNS-0.146ns、WHS+0.157ns、6个setup失败端点。相对上一候选6827/7203减少517 LUT、增加64 FF；不能当整机或路由通过。
- 已进入活动ar_video.sv，SHA256 cb71d4b1fa5661b710ace1a61ddf9eb6b502a292c6a6e8d66bd99f2da749a9ac。原5ns活动版本保存于results/ac880_ar_input_pipeline_20261006/ar_video_active_before.sv；仿真fixture与TB在活动sim_1/imports/tests，test_ac880_ar_pipeline.tcl验证新增2周期。
- 当前启动ac880_integrated_input_pipeline_20261006，先整机综合/约束值审计，完成后再看资源与物理门槛决定place。结果results/ac880_integrated_input_pipeline_20261006，日志vivado_project/logs/ac880_integrated_input_pipeline_20261006_status.log。无bit，无本轮上板；snapshot不动，五小时剩5%停止新任务并交接。

## AC880 第二轮物理实现完成，单次布线取证（2026-10-06）

- 第二轮place/phys_opt完整EXIT0：28,474 LUT（53.52%）、36,775 FF（34.56%）、Slice 12,274/13,300（92.29%）、66 BRAM36等效、73 DSP、1,491控制集。新增流水显著改善时序，但未改善Slice打包（上轮91.35%），该问题保留。
- WNS -0.258ns、TNS -14.421ns、91 setup失败端点；WHS -0.219ns、120 hold失败端点。相比上轮WNS-1.932/TNS-432.838/904端点大幅改善，仍不是签核通过。拥塞报告无level5以上窗口。
- 启动单次 route_design -directive Default 取真实布线证据，入口tools/scripts/route_ac880_pipeline_20261006.tcl，任务ac880_pipeline_route_20261006，结果results/ac880_pipeline_route_20261006。此脚本没有write_bitstream/JTAG命令，不做自动策略循环。时序负则保留报告并返回失败；需先看实际失败路径再修，不重复盲目route。
- 即使内部路由时序满足，还需审核完整route_status、bus_skew、DRC、外部IO时序及复位CDC后再决定候选bit；当前没有新bit，没有任何本轮上板结果。source_snapshot/snapshot全部不动。

## AC880 新流水级整机综合通过，进入第二轮布局（2026-10-06）

- ac880_integrated_pipeline_20261006 完整 EXIT0，主综合无Error/无Critical Warning；AR实际requirement5ns、统计8ns和覆盖审计通过。
- 实测整机 31,066 LUT、39,364 FF、66 BRAM36 等效、73 DSP、1,539 control sets。比新增流水级前多193 LUT/171 FF/2控制集。
- 整机综合WNS -0.479ns（原-2.053ns）、WHS -0.100ns。最差x→ch0为8级；仍43个setup失败端点，未闭合。
- 正在启动 ac880_pipeline_place_20261006，复用已审计综合DCP、opt→place→phys_opt；不包含route/bit。入口 tools/scripts/place_ac880_audited_20261006.tcl 支持两个结果tag，保持不同版本结果不覆盖。无新增整帧缓存，已确认仅5ns像素流水延迟。
- 下一步读 results/ac880_pipeline_place_20261006 的 physopt_device_utilization/physopt_timing/physopt_congestion/physopt_setup 等，重点比较上一轮Slice91.35%和WNS-1.932ns。物理结果负裕量或高拥塞时先改根因，不直接长时间route。RGMII/TFT外部IO时序及复位CDC审核仍待完成。

## AC880 AR 新增 5ns 流水级已进入活动工程（2026-10-06）

- 四项候选对拍全部 EXIT0：两种HUD各106,496像素随机背压对拍；两种HUD各106,496像素连续输入/背压/暖复位对拍。连续帧明确验证每拍1像素、比黄金版本恰好多1周期。参考像素流按共同接受输入与输出消费顺序比较，不要求不同深度流水线逐拍m_valid相同。
- 候选局部综合 EXIT0：6,827 LUT、7,203 FF，WNS -0.505ns、WHS +0.157ns。相对年龄tick版本6,659 LUT/7,041 FF，多168 LUT/162 FF；最差路径转为字符计数→font0，6级LUT，仍未时序闭合。
- 已替换活动 vivado_project/ac880/.../rtl/ar_video.sv；原活动版本保存在 results/ac880_ar_hit_pipeline_20261006/ar_video_active_before.sv。只新增每目标命中向量和字形数据寄存一级，不变目标数量/精度/协议。无背压时像素流水由2级变3级，增加5ns；停顿时三段整体冻结，帧更新/年龄仍以输入接受周期为准。新增datapath无reset，val0控制有效性。
- 黄金参考与两份新TB复制到活动sim_1/imports/tests，后续可用 tools/scripts/test_ac880_ar_pipeline.tcl 独立重跑，不依赖上传结果缓存。黄金fixture只用于仿真，不加入综合源层级。
- 下一步整机任务 ac880_integrated_pipeline_20261006：综合后明确校验AR5ns/统计8ns实际requirement和覆盖；然后根据实际资源、控制集和时序决定下一轮place。不启动route或bit，不能将候选局部WNS作为整机通过。
- 已知上一个物理结果Slice91.35%，仍需降低局部连线及改善packing；外部I/O契约、CDC复位组合警告、宽bus_skew审核仍未完成。snapshot禁止修改；5小时额度剩5%停止新任务并更新交接。

## AC880 布局后证据与下一版 AR 候选（2026-10-06）

- ac880_place_20261006 已完整 EXIT0，opt/place/phys_opt 均完成，未运行 route_design、未生成 bit。物理优化后 28,459 LUT（53.49%）、36,784 FF（34.57%）、Slice 12,150/13,300（91.35%）、66 BRAM36 等效、73 DSP。布局拥塞报告未发现 level5 以上窗口，不代表布线无拥塞。
- 物理优化 WNS -1.932ns、TNS -432.838ns、904 setup 失败端点；WHS -0.158ns、116 hold失败端点。最长路径 x→rh1，10级包含4个CARRY4；次长为x→ch1、字符计数→hh1。不能仅继续切换策略或长时间route。
- 独立候选 results/ac880_ar_hit_pipeline_20261006/ar_video_pipeline.sv：每目标plain/red/cyan命中分开寄存，再归并；HUD先寄存35bit字形，下一阶段选行列。增加1个200MHz像素周期（5ns，背压暂停时间另计），稳态每拍1像素；新增datapath不reset，仅val0控制有效性，全pipeline背压时冻结。帧首快照、年龄判定和发布应答仍在原输入接受周期完成，避免跨帧使用错误参数。
- 活动AR尚未替换。测试任务 ac880_ar_hit_pipeline_20261006 进行双HUD/32目标/随机背压、SOF/标志/原始像素流对拍后再局部综合；结果未完成前不能写通过。参考是上一版已经对拍通过的年龄tick版本。
- 下一步：先看候选仿真与局部timing/resource，必要时补连续输入吞吐/复位测试；通过且有实际改善再进入活动RTL和整机重新验证。若仍不收敛，进一步拆分视差加法与边界比较，而非添加整帧等待。snapshot不动，5小时剩5%停工。

## AC880 整机综合完成与约束修正（2026-10-06）

- 最新整机综合 EXIT0，实际资源 30,873 LUT、39,193 FF、63 RAMB36＋6 RAMB18（66 BRAM36 等效）、73 DSP、1,537 control sets。相对上一整机 33,367 LUT/37,078 FF，减少 2,494 LUT、增加 2,115 FF；不是布局/路由结果。
- 发现活动 perception_cdc.xdc 两段 if 被 Vivado XDC 解析器跳过，旧审计仅确认端点存在，未验证约束值，故此前统计总线 hold 仍 -1.625ns。已改成直接 XDC 约束命令，端点检查和具体 REQUIREMENT 验证移到 Tcl 构建审计。以后不能以“端点存在”代替“约束生效”。
- audit_ac880_constraints_20261006.tcl 在现有 DCP 重放约束，通过 AR 1750 源/1741 目的寄存器、5ns REQUIREMENT，以及统计64/64寄存器、8ns REQUIREMENT验证；EXIT0。修正后 WNS -2.053ns、WHS -0.100ns；TIMING-6/7/15 Critical/大跨域hold告警消失。TFT错误内部主时钟也已消失。
- 已启动 tools/scripts/place_ac880_audited_20261006.tcl：opt→place→phys_opt，输出 results/ac880_place_20261006。未启动route，未生成bit。先复用综合DCP而非重复综合，活动约束已持久化；重综合后仍应跑具体约束值/覆盖审计。
- 待解决：200MHz AR仍4个setup失败端点；剩余少量hold；未约束外部输入/输出需要实际接口时序依据。TIMING-9 bundled握手识别、TIMING-32宽总线bus_skew、控制集及厂商IP警告保留审核，不能仅因无Critical宣称签核完成。
- 下一步读取布局后Slice/拥塞/最差路径。若主要仍为x→红眼命中串联加法比较，先优化坐标/边界计算或增加明确5ns流水级并对拍，再决定route。原始流吞吐和算法精度不变，不新增整帧缓存；snapshot完全不动。

## AC880最终本轮改动与顺序综合（2026-10-05）

- 活动AR已包含帧首三位命中、视频域提前快照、四个距离数字字形预译码、控制域年龄tick换算。外部年龄输入仍是微秒；holding内部年龄字段改为饱和视频tick。年龄乘法在原有32周期BCD计算完成时提交，无额外发布/像素周期。对支持的VIDEO_HZ=1/200MHz且超时阈值小于UINT32_MAX，先饱和再加pending与最后饱和等价；150ms/1s失效判定相同。
- 字形六项回归通过：局部6655 LUT/7049 FF，像素slack -2.462ns。年龄版本六项回归及逐拍age/motion_age/live/motion_live比较通过：局部6659 LUT/7041 FF、0 BRAM/DSP，像素slack -1.733ns、WHS +0.157ns，4个setup失败端点。局部未布局，不宣称时序闭合。原AR基线8962 LUT/5062 FF，净减少2303 LUT、增加1979 FF。
- 状态CDC稳定窗口测试EXIT0，独立复位/源断钟/回绕/收敛与采样前后8ns稳定断言通过；新增模块ac880_status_cdc已接入活动top，只改变统计信息的采样延迟，不改变原始雷达、底盘或视频数据路径。源复位排空16×8ns，正常握手约几十至百ns，准确板测值待验证。
- TFT Clock Wizard通过Vivado BD属性CONFIG.PRIM_SOURCE=Global_buffer修正；validate/save/generate EXIT0。生成的system_tft_clk_0.xdc中错误内部create_clock已变为注释。100MHz输入及31.016MHz输出频率未修改，无额外视频缓存。整机methodology确认仍待本次综合。
- 当前任务ac880_integrated_ar_20261005：顺序最终局部综合→整机综合→CDC约束端点/覆盖审计；监控PID2076仅作历史定位，下次查真实进程。日志vivado_project/logs/ac880_integrated_ar_20261005_vivado.log及_status.log，整机结果results/ac880_integrated_ar_20261005。当前在整机综合过程中，不能用局部净变化直接当作整机总数。
- 本次入口tools/scripts/synth_audit_ac880_20261005.tcl，复用原整机synth脚本，增加活动status模块，不引用或编辑snapshot。输出确认AR/统计bundled总线端点存在、report_exceptions覆盖和错误TFT主时钟消失；脚本不运行place/route/bit。
- 下一步先读取退出码、真实LUT/FF/BRAM/DSP/control sets、各时钟WNS/WHS、CDC及methodology。资源/约束审计通过后只先布局与phys_opt，核对Slice、拥塞及关键路径，再决定route；不能把预估route延迟当作已布线结果。
- 待解决：最终AR x寄存器→红眼命中仍11级、4 CARRY4，局部估算6.730ns；其中布线估算4.224ns，先看整机/布局证据再决定是否需要一个5ns坐标流水级。不能为追求源码简短重新引入宽SOF MUX、动态字体译码或像素域年龄乘法。
- 全部snapshot不动；停工线五小时额度剩余5%，周额度忽略。无新bit、无本轮上板结果，不推送Git。

## AC880继续优化：帧首窄标志与统计CDC（2026-10-05）

### 已完成证据

- 帧首预计算版本六项对拍全部通过，包括原版周期/像素、两种HUD、普通/红青AR、随机背压、旧结果撤框及32次同步临界发布。0新增像素周期，仍每拍一个像素。
- AR局部综合：原版8962 LUT/5062 FF；仅提前快照9858 LUT/6687 FF；提前快照+帧首预计算6633 LUT/6703 FF。BRAM/DSP均0。最差像素slack -4.260→-3.186 ns，未知CDC Critical 4→0，仍未完成时序签核。
- 帧首坐标固定(0,0)，控制域预计算普通/红/青命中三位；正常像素只用active目标参数，不再通过SOF选择整个宽总线。首像素选少量标志，保留原先live_q、过期和风险语义。active目标在SOF更新。
- source_fifo_overflow与source_eth_rejected改为64位一体握手快照，源125MHz、目的100MHz；源held_data维持至应答，三个同步级后目的采样。源复位后16个源周期（128ns）排空旧握手。独立复位、计数回绕、源时钟暂停、最终收敛、采样前后8ns稳定断言通过。该延迟只影响统计刷新，不影响雷达字节、感知或视频吞吐。
- 统计CDC新增约140个FF及少量控制逻辑，无BRAM/DSP；实际整机数待综合。只对held_data→dst_data限定8ns max_delay/bus_skew，首级请求/应答单比特同步例外，不豁免整个时钟域。

### 正在验证与下一步

- HUD距离四位字形预译码候选results/ac880_ar_cdc_20261005/ar_video_glyph.sv；以4×35bit小型寄存器字形槽替代像素域BCD选位/ASCII加法/字体译码，理论增加420个FF（三份140bit），不增像素周期。候选六项测试进行中，尚未进入活动RTL，不作通过声明。
- 先完成字形测试和局部综合；通过后更新活动AR与源码哈希，整机综合检查资源、control sets、时序、CDC与约束匹配，再决定布局。未生成新bit。
- 单独背压剪枝任务ac880_ar_ready_20261005失败在Vivado Spawn failed: Broken pipe，未取得仿真结果。其后帧首候选用新目录完成全部验证，不能把工具启动异常写成当前RTL失败。
- 现有TFT Clock Wizard把内部PS FCLK设成Single_ended_clock_capable_pin，报告TIMING-4/27重复主时钟。尚未修复；不得直接改生成XDC。下轮应核查BD时钟输入来源及OOC约束是否错误用于整机。

### 今后写法要求

- 优先缩小关键时钟域的选择/译码网络；固定边界像素采用可证明等价的窄标志，不广播宽状态总线。
- 控制域预计算小型只读字形，与发布握手和帧边界一致；大型动态图像继续流式传输，不据此复制整帧寄存器。
- CDC必须证明源数据保持窗口、同步级、物理max_delay/bus_skew与复位恢复；数字仿真一致不等于亚稳态或板级验证。
- 不在构建读取源码期间修改输入。候选先在results离线验证，通过后才进入现行ac880。snapshot完全不动，常规综合20线程，仿真诊断单线程。
- 本轮停工线为五小时额度剩余5%，忽略周额度；源码采用GBK无BOM，文档UTF-8无BOM。

## AC880 AR跨域快照优化进度（2026-10-05）

本节仅更新AC880旁线，ACX750已验证镜像与其他任务保持原状。五小时额度剩余5%停工，周额度忽略；所有snapshot目录禁止修改、移动和删除。

- 已核实上次整机综合EXIT0：33367 LUT、37078 FF、63 RAMB36+6 RAMB18（66个BRAM36等效）、73 DSP、1529 control sets。整机综合WNS -4.789 ns、WHS -1.614 ns，100 MHz域setup最差+1.010 ns；不是路由签核。
- 本轮活动ar_video增加无复位staged快照寄存器：两级请求同步后锁存holding，下一拍三级同步请求用于原有SOF切换。帧首不再直接从异步holding经MUX流入像素比较树。捕获标签复位保证未写数据不会生效；holding保持到SOF应答。
- 活动perception_cdc.xdc仅对holding→staged设置5ns datapath最大延迟和5ns bus skew；未将该数据总线设为false path。保留既有请求/应答同步器首级例外。整机后必须确认约束实际匹配、CDC路径和布局后的物理裕量。
- 像素流水线仍为原有两级、每拍吞吐一个像素，发布及SOF应答周期不变；增加约BW个FF（32目标精简HUD时1657个），无BRAM/DSP需求，精确资源以综合报告为准。
- 验证：双HUD模式与原版本周期/像素对拍、普通及红青AR、旧结果撤框、随机背压五项通过；额外32次发布、独立100/200MHz、同步临界SOF及4096像素对拍通过。仿真不证明亚稳态裕量。
- 新SOF测试首次超时属于驱动错误：在请求尚未同步的SOF之后等待publish_ready，却不再提供SOF，因此双方都无法应答。修正为每次发布提供两帧，DUT未因测试超时更改。首次失败日志保留，不能当作最新失败。
- 原件和证据位于results/ac880_ar_cdc_20261005；局部前后综合正在统一监控任务ac880_ar_cdc_synth_retry_20261005内运行。完成后检查像素路径、CDC、资源与control sets，再启动整机综合；不直接启动route或生成bit。
- 已发现待修：雷达FIFO溢出与以太网拒包32位统计直接125→100MHz读取，需要有复位语义的CDC方案和专门测试。不要仅给32位binary计数加同步器；Gray方案须保证每拍0/+1及复位后的有效性，握手快照须证明总线稳定、更新周期与暖复位恢复。

# FPGA工程构建与优化

整理：2026-10-03。先读[项目总交接](项目总交接.md)，本册保留来源与历史版本，正文旧路径及待办不自动成为当前要求。

## 阅读说明

集中保存Vivado标准工程、时序/资源/存储修复和Route专项审计。AC880及Full的旧报告不是当前通信bit报告，修改前读取各自最新报告和总交接。编译前检查规则独立保留。

## 内容目录

- [AC880继续修复交接_2026-10-03.md](#doc-001)
- [AC880资源与时序优化_2026-10-02.md](#doc-002)
- [ACX750通信版HDMI离线改造_2026-10-01.md](#doc-003)
- [Full存储结构优化_2026-10-02.md](#doc-004)
- [HDMI工程标准结构整理_2026-10-02.md](#doc-005)
- [HDMI迁移交接_2026-10-01.md](#doc-006)
- [MIGRATION_HANDOFF.md](#doc-007)
- [Route_Design专项审计_2026-10-01.md](#doc-008)
- [vivado_project/source_snapshot/fpga_acx750/scripts/README.md](#doc-009)
- [vivado_project/source_snapshot/fpga_acx750/sim/README.md](#doc-010)
- [vivado_project/source_snapshot/fpga_acx750_full/scripts/README.md](#doc-011)
- [vivado_project/source_snapshot/fpga_acx750_full/sim/README.md](#doc-012)
- [存储结构修复交接_2026-10-01.md](#doc-013)
- [时序修复归档_2026-10-01.md](#doc-014)

---

<a id="doc-001"></a>

## 来源：AC880继续修复交接_2026-10-03.md

## 本轮停工记录（2026-10-03，五小时额度剩余36%）



本轮最新要求为五小时额度剩余40%停工，不考虑周额度。检查时已剩余36%，停止新增开发与构建，仅完成交接记录。



- 已完成：底盘速度归一化增加一级寄存器，消除除法与滤波串联长路径；局部 LUT 1177→637、FF 830→752、DSP 3→4，局部综合最差 slack -5.574 ns→+3.719 ns。增加1个100 MHz周期，即10 ns，忙窗口增加1周期。

- 验证：原有边界用例及256组随机速度、忙时输入和结果对拍通过。局部时序通过不代表整机路由时序通过。

- 正在运行：ac880_integrated_motion_fix 整机综合；停工读取日志时处于 Technology Mapping，尚未完成。保留已启动任务，不启动布局布线。结果目录 results/ac880_integrated_motion_fix_20261003；日志 vivado_project/logs/ac880_integrated_motion_fix_vivado.log，退出状态见同目录 ac880_integrated_motion_fix_status.log。

- 最近已完成的整机基线：34272 LUT、37157 FF、63 RAMB36+6 RAMB18（66个BRAM36等效）、72 DSP；综合 WNS -5.763 ns。这些是底盘修复前数据，不能当作新版本结果。

- 下次先读取此次综合退出码及新资源/时序报告，对比上述基线；成功后定位剩余最差路径，优先处理200 MHz AR链路与跨时钟约束/CDC。不得用错误 false path 或放宽频率掩盖问题。

- 尚未完成：整机时序收敛、布局布线、通过DRC的候选bit及上板验证。没有可宣称验证通过的新镜像。

- 编码与工程边界：仅修改现行 vivado_project/ac880，保留旧工程；RTL/XDC/Tcl采用CP936无BOM，文档采用UTF-8无BOM。先判断实际硬件结构，采用可靠同步RAM模板、合理位宽和明确CDC；流水线修改必须报告延迟与吞吐变化，并对拍。常规构建通过图形监控入口、20线程。



## 底盘时序修复与新停工线（2026-10-03，覆盖此前60%）



用户最新指令：继续修880，五小时剩余40%停工，周额度忽略。



### 第一轮整机综合已经成功



`ac880_integrated_synthesis_20261003_status.log` EXIT0，不是失败。实际总LUT34272、FF37157、RAMB36=63/RAMB18=6（等效66）、DSP72。整机综合WNS−5.763ns，不等同路由签核；最差在motion sqrt/root→area DSP输入，28级，15.151ns，已据此修改。



### 本轮修改与通过证据



- 仅修改AC880活动chassis_motion，复用750已有norm_product/norm_speed流水线；保存原模块为 `results/ac880_motion_timing_20261003/chassis_motion_before.sv`。

- 平方根输出先乘常数52429并寄存，再右移18位得到速度；滤波使用norm_speed寄存值，不再直接重复raw_norm/5。穷举0..65535与整数除以5完全一致；实际16bit速度范数≤46340。

- 增加1个100MHz控制周期（10ns），忙状态增加1周期。极限吞吐间隔相应增加1周期；正常低速Odom不受影响，若新帧恰好落在新增忙周期则仍按忙帧计数丢弃，无队列或协议修改。未增加视频延迟/整帧等待。

- 原极值、最大dt、异常dt不积分、断流、余数保持对拍通过；补256组随机速度，每组忙时插入额外帧，输出数值和overflow=256与旧模型一致，EXIT0。

- 同一7020/10ns局部综合：LUT1177→637、FF830→752、DSP3→4；最差slack−5.574→+3.719ns。新最差是last_us→CE长时间差控制路径，不再是速度除法到乘法器。OOC时钟位置未知，仍需整机/路由确认。

- 证据 `results/ac880_motion_timing_20261003/{before,after}_{utilization,timing}.rpt`、simulation.log；日志ac880_motion_timing_vivado.log和ac880_motion_extended_vivado.log。



### 当前运行与下次入口



底盘修复后整机综合已启动：任务ac880_integrated_motion_fix、监控父PID12884（下次重新查存活），入口 `tools/scripts/synth_ac880_integrated.tcl -tclargs ac880_integrated_motion_fix_20261003`。日志 `vivado_project/logs/ac880_integrated_motion_fix_vivado.log`、`_status.log`；新报告在 `results/ac880_integrated_motion_fix_20261003`，保留第一轮基线。没有启动place/route/bit。



下次先读本次整机综合结果、资源、最差路径及CDC；不要覆盖旧报告来比较。AR ack→rh1的200MHz路径仍未修改，下一项考虑拆开快照选择、偏移与比较/汇总，保持SOF原子切换和随机背压对齐；先明确增加几个5ns周期，黄金像素对拍通过后局部综合，最终按整机路径决定。不能用错误false path或降频掩盖。



代码规范和编码仍沿用下文；新datapath norm_product不做无必要reset，由FSM有效性保证读时已写。只改新工程，不动750、厂商或旧项目；20线程默认保留，所有编译经统一监控。



# AC880 继续修复交接（2026-10-03）



## 最终停工状态（五小时剩余60%）



本轮最后额度读取已用40%、剩余60%，按用户规则停止新开发，只补交接。周额度忽略。



- **BD刷新完整通过、EXIT0**：唯一 `ac880_perception_regs_axi` 生效，validate/save/generate/wrapper完成；BD JSON和生成wrapper直接审计通过，新IP为system_perception_regs_0_1，生成synth包装确实实例化唯一模块并连接reset。原地址保留。日志 `ac880_bd_unique_wrapper_vivado.log`，标记 `AC880_LOCAL_BD_REFRESH_PASS`。

- **AR对比综合完整通过、EXIT0**：LUT9263→8962，FF5050→5062，BRAM/DSP0，新增像素延迟0周期。完整和compact黄金差分及三项原回归通过。

- **AR时序未关闭**：同200MHz局部综合估算最差slack−5.742→−4.260ns。原x→HUD路径已不再居首；当前ack_reg→rh1_reg，13级、数据路径9.257ns，其中逻辑2.430/估算布线6.827ns。这是未布局OOC估算，并有HD.CLK_SRC未指定警告，不能等同路由后WNS。

- **完整7020综合已启动，仍在运行**：统一监控任务 `ac880_integrated_synthesis_20261003`，入口 `tools/scripts/synth_ac880_integrated.tcl`，日志 `vivado_project/logs/ac880_integrated_synthesis_20261003_vivado.log`；后台监控父PID35260（下次需重新查是否存活，不凭PID猜测）。已启动任务继续运行，本轮不启动布局布线/bit。

- 其他750构建未触碰。当前仍没有优化后整机资源数、候选880 bit/XSA或上板结果。



### 下次最先做



1. 读整机综合 `_status.log` 和Vivado日志，再看 `results/ac880_optimization_20261003/integrated_utilization.rpt` 等；如果失败，按首个实际错误修复，不能把准备好的脚本当成构建通过。

2. 核对新system_perception_regs_0_1是否有独立OOC运行、是否强制更新；来源必须是活动 `ac880_perception_regs_axi`＋`ac880_perception_regs`，不能旧DCP或旧snapshot。主综合门禁会检查wrapper端口及来源，报告包含CDC/时钟/控制集。

3. 资源合理后针对 **ack/SOF swap→holding/active多路选择→红青偏移加减→32目标比较→命中汇总** 做下一项AR优化。适合将每像素边界选择/移位与比较拆为受同一ready控制的阶段，或在控制域预计算移位后的边界；必须先明确增加的几个5ns周期、首帧SOF原子切换和背压对齐，用黄金逐像素对拍。不要把ack跨域握手标成错误false path来掩盖像素域内部组合路径。

4. 不重复跑已通过的配置/引擎/CRC/HUD测试；针对下一项修改新增必要覆盖。只有整机资源、Slice、控制集和布局报告合理后才长route。



## 边界与当前结果



只修改标准 `vivado_project/ac880` 活动源码和必要构建/测试工具。750 的另一项构建正在运行，不中断或改其工程。远端已 fetch，HEAD 与 origin/main 无差异；本地未提交修改保留，未上传。



用户规则：**五小时剩余达到60%停止新工作并完成交接；周额度不作为停工条件。** 默认请求20线程；诊断工具初始化/仿真期间单线程是专项例外，不代表全局降低构建线程。



## 已通过



- 配置寄存器与引擎既有回归恢复通过；两种雷达点型 CRC/有符号坐标测试通过。日志 `vivado_project/logs/ac880_resume_regressions_vivado.log`，最终 `AC880_RESUME_REGRESSIONS_PASS`、EXIT0。

- AR 新硬件结构：用握手驱动的 HUD 字符/子像素计数器替代200MHz路径的 `/12`、`%12`；字体采用7个固定行选择，消除大位宽变量移位。计数只在像素被接受时推进，SOF/EOL/左边距复位。

- 原HUD、普通AR、compact AR三项回归通过：精确像素、随机背压、SOF更新、普通/红青、旧目标撤框。

- 额外黄金差分在 compact=1 和 compact=0 均通过：2048×24 全横坐标范围，独立控制/视频时钟、随机背压；与修改前参考逐周期比较数据、valid/ready、SOF/EOL及发布握手。

- **AR仍为原两级像素流水线，新增延迟0周期，稳态吞吐1像素/周期**，未修改显示内容、算法精度、接口或时序频率。



## 正在验证／未完成



- AR相同XC7Z020/100MHz控制/200MHz视频的修改前后局部综合与资源、控制集、内部路径报告正在生成。入口 `tools/scripts/test_and_synth_ac880_ar.tcl`；日志 `vivado_project/logs/ac880_ar_equivalence_and_synth_vivado.log`。

- 旧模块引用在正确活动源码下仍返回旧lut_words边界，`update_module_reference`空错误，重建同名引用也无lut_index。已改唯一包装模块 `ac880_perception_regs_axi`，保持cell名 `perception_regs_0`、GP1地址 `0x80420000/4KB` 及其他连接；已经通过完整刷新及新接口生成审计；同名边界缓存问题通过唯一名称规避，但不宣称已定位工具内部唯一根因。

- BD刷新入口 `tools/scripts/refresh_ac880_local.tcl`；最新日志 `ac880_bd_unique_wrapper_vivado.log`。只有 validate/save/generate/make_wrapper 全完成才记通过。

- 整机综合入口已准备 `tools/scripts/synth_ac880_integrated.tcl`：要求新wrapper有perf_lut_index/perf_lut_word且无旧perf_lut_words，检查编译来源无source_snapshot，强制重跑配置模块OOC，再综合并导出资源/控制集/CDC/时钟/方法学报告。尚未启动，不自动布线或出bit。

- 现无新的完整bit/XSA、布局布线签核或880上板结论。昨日整机BRAM约66只是假设其余模块不变的估算，当前仍无优化后整机统计。



## 工具问题与试错



1. 昨日Tcl source读取错误今天仍不稳定，错误文件变化，文件实际存在；单线程IPI初始化仍曾失败。未改SDK文件、未删规则、未降级错误。

2. 增加 scoped source 重试：仅捕获“确切目标文件存在、打开失败”的指定I/O错误，最多3次，改原生Windows路径；其他错误立即失败。没有跳过规则执行。块图后续能打开，但不能据此宣称唯一根因。

3. update_module_reference 空错误；活动编译顺序已确认是本工程perception_regs_ram/axi，非snapshot；重建同名cell仍拿旧端口。现在尝试唯一AXI包装名。

4. 模块替换脚本第一次AXI连接缺少第二对象，已改为sensor_ctrl/M02_AXI与新s_axi显式连接。失败前未save BD，原BD备份在 `vivado_project/logs/archive/ac880_opt_20261003/system_before_refresh.bd`。

5. 工具回归改独立运行目录、最小源码依赖后通过；不认定此前Tcl_Close/Broken pipe唯一原因。后台统一监控入口保障会话结束后任务状态可查。



## 接下来按顺序做



1. 读取上述两项运行的末尾日志与监控job状态；先区分工具失败、接口失败和RTL失败，避免重复跑已通过回归。

2. BD通过后检查wrapper、新AXI模块端口、reset及原地址；生成的配置IP必须实例化唯一新包装和RAM核心，强制更新OOC缓存，不能消费旧DCP。

3. 运行整机综合入口，核对LUT/FF/Slice/BRAM/DSP/控制集；补充实际整机资源，替代3.3～3.5万LUT/66BRAM的估算。

4. 资源合理后，检查200MHz视频域实际最差路径、CDC/RDC和拥塞；先布局报告审查再长route。时序门限WNS/WHS≥0、无DRC Error及引脚Critical Warning，不乱加false/multicycle、不降低频率。

5. 最后才生成候选bit/XSA并安排实机；PS USB、雷达、底盘、DMA、AR、TFT各项单独验收。



## 编码与开发要求



继续遵循 [FPGA/嵌入式/桌面规范](07_开发工具与规范.md#doc-001) 和 [昨日优化要求](04_FPGA工程构建与优化.md#doc-002)：先推演综合硬件、BRAM/控制集/扇出/CDC，再按仿真→局部综合→整机资源/时序→布局布线验证；每次改动记录延迟和吞吐。HDL/XDC/Tcl为CP936/GBK无BOM；文档/Python/JSON为UTF-8无BOM。所有MD在docs，根readme仅索引。



源哈希 `results/ac880_optimization_20261003/source_hashes.json`；参考AR保存在同目录ar_video_before.sv，昨日备份保持不变。

---

<a id="doc-002"></a>

## 来源：AC880资源与时序优化_2026-10-02.md

# AC880 资源与时序优化（2026-10-02）



## 修改边界与当前结论



用户重新授权优化标准 `vivado_project/ac880/ac880.xpr`，沿用 750 已验证的存储和流水线方法。750 两工程、旧项目、source_snapshot、厂商原工程未修改。相机保留 PS USB，帧缓存使用 PS DDR；PL 保留雷达感知、底盘计算、投影和 AR。



**模块仿真与局部综合已取得结果，整机接口刷新尚未完成。当前工程处于修改中，不能作为可加载镜像。尚未重新完成整机综合、布局布线、bit/XSA 或上板验收。**



原始源码和 SHA256 在 `vivado_project/logs/archive/ac880_opt_20261002/original_sources.json`；本轮报告与检查点在 `results/ac880_optimization_20261002`。



## 已完成修改及工具证据



| 项目 | 修改和结果 | 边界 |

|---|---|---|

| 栅格存储 | objects/visited 唯一写端口，消除寄存器式大选择网络；存储阶段差分 703835 周期、4 次发布通过 | 栅格/目标精度不变 |

| 栅格运算 | 地面乘加分级、精确 ROI 距离平方、100mm 地址计算和邻接索引分级 | 512 地面向量、6600 边界坐标及 4 次拒收、3300 格邻接检查通过 |

| 配置寄存器 | `perception_regs_axi.v` 补接 `s_axi_aresetn`；唯一模块名 `ac880_perception_regs` 避免旧快照同名引用 | BD/OOC 重新生成后还须核对实际编译来源 |

| 畸变表 | 两个 221×32 同步 BRAM 银行；7072bit 展开接口改为 8bit 地址、32bit 数据 | 表、字节写、部分更新、提交、复位、AXI 停顿测试通过 |

| 结果快照 | 双槽 BRAM 顺序写入 416 个 word，完成后原子发布；不整体 reset memory | 416word 内容、一致性、无效地址和复位测试通过 |

| 定点投影 | 对同步表读取增加等待状态 | 与原异步表参考逐项对拍，目标数 1/32/0 及无标定模式通过 |

| 雷达 CRC | CRC 更新和最终比较拆开一拍 | 专项回归因 Spawn failed: Broken pipe 在 elaboration 启动阶段失败，未取得功能结果 |

| 工程维护 | `finish_ac880.tcl` 改为刷新活动源码，不重新导入 source_snapshot | 工具初始化失败，生成 wrapper 尚未成功 |



同一 XC7Z020、10ns 局部综合比较：



| 模块版本 | LUT | FF | BRAM36 等效 | DSP | 控制集 |

|---|---:|---:|---:|---:|---:|

| 原始栅格 | 11083 | 13730 | 53.5 | 20 | 249 |

| 仅存储优化 | 3263 | 1359 | 53.5 | 20 | 未摘录 |

| 存储加运算分级 | 3034 | 1441 | 53.5 | 17 | 67 |

| 新配置/快照模块 | 1474 | 5275 | 3 | 0 | 见报告 |



栅格减少 **8049 LUT、12289 FF**；这只是模块同配置比较，不能相加当成整机节省或宣称 7020 已能装下完整功能。新寄存器模块增加 3 个 RAMB36，须纳入整机 BRAM 总量检查。



原整机综合 41081 LUT/43281 FF；旧路由 32366 LUT/35140 FF、WNS -6.126ns。旧配置 IP 使用旧 snapshot 且复位漏接，曾被裁成零资源，因此旧统计不代表完整功能。



## 延迟和吞吐



- 地面乘加增加 2 个点流水线周期，100MHz 下为 20ns；边界/整数结果已对拍。完整扫描处理耗时仍须整机验证。

- CRC 比较增加 1 个包处理周期，100MHz 下为 10ns；不增加整帧等待。

- 同步畸变表投影每角点增加 4 周期；32 个目标最大增加 1024 周期，即 10.24µs；无标定模式增加 0 周期。像素流速率不由此降低。

- LUT 上电初始化 221 周期（2.21µs）；提交后克隆表 442 周期（4.42µs），pending 期间暂停算法输入。须验证上游 FIFO 足够承受这段暂停。

- 快照写入 416 周期（4.16µs），相较原 32 周期增加 3.84µs；busy/序号保护中间数据，软件应按一致快照读取。



## 未解决问题



### BD 工具初始化（最高优先级）



`refresh_ac880_local.tcl` 的 `open_bd_design` 失败。先出现相对路径 `replace_bd_cell.tcl` 读取问题，限定工作目录后变成 ai_engine 工具脚本读取失败。预加载 helper 后仍有 roe_framer auto_utils.tcl 和 ai_engine bd.tcl 读取错误。Windows 检查 auto_utils.tcl 实际存在，不能直接断言安装文件缺失。



这些是工具初始化错误，尚不是设计接口验证结果。未删除厂商规则、未压低错误等级、未修改 Vivado 安装目录。活动顶层已改新 LUT 接口，但 BD 和 system_wrapper 仍未成功更新，必须先解决并重新生成，不能直接运行旧 wrapper 后声称集成通过。



### 旧综合入口回归



`test_ac880_existing.tcl` 在 launch_simulation 期间触发 `called Tcl_Close on channel with refCount > 0`，退出 3。没有得到 regs/engine 功能仿真结果；不能当作 RTL 功能失败或通过。专用 RAM 和投影测试已独立通过，不替代整机引擎回归。



### 原 AR 关键路径



实际旧最差路径是 overlay x_reg[4]→hh1_reg/D，视频 AXIS 为 FCLK1 **200MHz/5ns**；15 级逻辑，11.026ns 数据路径，其中约 8.923ns 为布线，WNS -6.126ns。不能以 TFT 像素时钟约 31MHz 评估此路径。此次存储修改尚不能证明该 AR 时序问题已解决。



## 下一步：具体顺序



1. 先诊断工具文件读取/初始化：保留原日志，在独立最小工程验证 IPI open；核对完整工具环境和文件读取，不屏蔽规则。日志为 `vivado_project/logs/ac880_bd_helper_preload_vivado.log`。

2. 修复后运行 `tools/scripts/refresh_ac880_local.tcl`；验证 BD 新 perf_lut_index/perf_lut_word 端口、wrapper、配置 reset 及编译来源。确认 OOC 编译唯一新模块，不再引用旧快照。必要时清理对应旧 OOC 运行，不能仅刷新主综合。

3. 重新完成 regs/engine 回归；修复子进程启动后重新验证 CRC，结果按实际 PASS 标记归档；再运行同步 LUT/快照压力与 FIFO 暂停验证。

4. 通过统一监控执行整机综合（16 线程），检查各层 LUT/FF/Slice/BRAM、控制集和时钟；重点核查 BRAM 是否超限。局部结果不能代替整机资源。

5. 依据新时序路径最小修改 AR 流水线，明确像素背压、帧边界和新增周期；先像素对拍再局部综合。

6. 整机资源和布局检查合格后才布线；WNS/WHS≥0、DRC 无 Error/引脚类 Critical Warning，并独立审查 CDC/RDC，方可生成候选 bit/XSA。最后才上板验收。



所有构建通过 `tools/run_build.py`，窗口自动显示，重任务顺序运行。局部综合入口 `tools/scripts/synth_ac880_local.tcl`；存储差分入口已固定读取保存的 storage 阶段源码，避免误将后来新增的流水线延迟当作差分失败。



## 后续写代码必须遵守



1. FPGA 代码先推演实际硬件结构；完整设计包含 RTL、XDC、工具设置和实现结果，不能套用桌面程序的数组、循环和动态索引习惯。

2. 大存储优先同步 BRAM；不整块复位，使用 valid/顺序初始化；多个赋值分支须汇成明确的物理端口。查看实际推断报告。

3. 不无必要展开巨型 MUX、宽总线和独立 CE/reset；注意控制集和 Slice packing，LUT 不高也可能严重拥塞。

4. 算术按实际范围选位宽；常量除法须范围证明和边界对拍；乘加在具体节点寄存，明确新增周期和吞吐。

5. CDC/RDC 按实际时钟域设计同步器、握手和 async FIFO；不以错误 false path/multicycle/降频掩盖真实问题。

6. 嵌入式软件按 DMA 缓冲所有权、缓存一致性、有限队列及断流恢复设计；桌面代码承担可变复杂度的展示和分析，不把该算法写法直接搬进 PL。

7. 修改只进入新工程活动 .srcs；旧工程和备份只用于参考。按语法/仿真/局部综合/整机资源/时序/布局布线/上板逐级验收。

8. HDL/XDC/Tcl 使用 CP936/GBK 无 BOM；文档/Python/JSON 使用 UTF-8 无 BOM；中文 PowerShell 使用 UTF-8 BOM。所有 Markdown 在 docs，外部仅 readme 索引。



## 额度与交接



用户最新规则：**只看五小时窗口，剩余达到 60% 即停止新工作并汇报，不看周额度**。最终读数五小时已用43%、剩余57%，本次检查已越过60%停工线，立即停工。相邻检查从63%变为57%，未启动整机综合或布线。已启动任务均已结束；CRC退出1，错误为 Spawn failed: Broken pipe，不能记为功能通过。只补交接，不再开展新开发。

---

<a id="doc-003"></a>

## 来源：ACX750通信版HDMI离线改造_2026-10-01.md

# ACX750 通信版 HDMI 与按键离线改造（2026-10-01）



## 当前任务



用户确认显示器原生为 1024×600，板卡暂不在手。仅修改 `vivado_project/acx750` 通信版；Full 由另一会话处理，本轮未修改。所有 HDL/XDC 使用 GBK/CP936 无 BOM；新文件采用 ASCII 注释。Markdown/Tcl 使用 UTF-8 无 BOM。



本记录是整合通信版的改造，和此前独立 `acx750_hdmi_bringup` 彩条工程不同。此前候选 bit 的时序报告不能作为本轮整机证据。



## 硬件结构与参数



- 从 50 MHz 输入增加独立 MMCM；保留原系统 MMCM 的 DDR、100 MHz 控制和 24 MHz 相机时钟。

- 默认 `HDMI_NATIVE_600=1`：像素 51.25 MHz、串行 256.25 MHz，严格同一 MMCM 的 5:1 比例。

- 光栅使用厂商 `Resolution_1024x600` 的 H/V total 1344×628、HS/VS 136/4、back porch 160/23、front porch 24/1；刷新率约 60.72 Hz。

- 输出有效区 1024×600；中央 800×480 为原图像区域，四周黑边分别 112/60 像素。不缩放，不新增帧缓存；数据源仍为 800×480、RGB565。

- `HDMI_NATIVE_600=0` 为构建时兼容选项：800×480，像素 33.333 MHz，串行 166.667 MHz。运行中按键不改变 MMCM 或分辨率。

- 取数保持旧 `AHEAD_CLK_CNT=2` 和两级请求寄存器。HDMI 编码/串行仅引入像素级延迟，没有整帧排队；实际端到端延迟需实机测量。

- 4 路 OSERDESE2 master/slave、OBUFDS 输出 TMDS。当前为 DVI 兼容视频，无音频、EDID、HDCP。显示器是否接受该时序仍待实测，不能仅凭原生分辨率保证兼容。

- 相机真实采集、DDR 图像映射与网络缺陷没有因更换 HDMI 自动修好；候选图像必须分别验收。



## 按钮（按厂商整板约束）



| 按钮 | FPGA 脚 | 操作 |

|---|---|---|

| S0 | D21 | 原系统复位，回启动模式 |

| S1 | E21 | 前一个阶段，0→7 |

| S2 | G22 | 后一个阶段，7→0 |

| S3 | G21 | 摄像头模式 3 |

| S4 | B22 | 彩条模式 0 |



按键低有效、双触发器同步、10 ms 去抖，一次按下产生一次命令，长按不重复。多个按钮同时通过去抖时 S4>S3>S2>S1。UART 调试命令保留；同拍按钮优先。



HDMI CLK J19/H19；D0 K21/K22；D1 J20/J21；D2 J22/H22；OE M22。活动约束排除原 LCD 管脚文件，加入 `acx750_hdmi.xdc`；不降低 DRC 等级。



## 文件与构建入口



- `acx750.srcs/sources_1/imports/rtl/acx750_top.sv`：HDMI、按键、独立视频时钟和新光栅接入。

- `imports/common/acx750_buttons.sv`：按键同步与去抖。

- `imports/display/acx750_hdmi_canvas.sv`：原画面居中的光栅。

- `imports/display/acx750_hdmi_clocks.sv`：像素与串行公共 MMCM。

- `imports/display/acx750_hdmi_tx.sv`、`acx750_tmds_encode.v`：TMDS 编码和专用串行器，编码器来自厂商参考。

- `acx750.srcs/constrs_1/imports/constraints/acx750_hdmi.xdc`：HDMI、按钮引脚。

- `acx750.srcs/sim_1/imports/sim/tb_hdmi_offline.sv`：原光栅对照、整帧计数、按键、时钟和串行控制码测试。

- `tools/scripts/setup_acx750_hdmi.tcl`：更新活动 XPR 文件集；不修改 Full。

- `tools/scripts/test_acx750_hdmi.tcl`：仿真；构建继续使用 `tools/scripts/build_750.tcl acx750 preflight` 与整机门限。



所有测试和构建通过 `tools/run_build.py` 编译监视器启动。首轮 Vivado 子进程报 `Spawn failed: Broken pipe`；重试时仅当前构建进程 TEMP/TMP 设为 `vivado_project/logs/tool_tmp`，不修改系统环境或 ACL。



修改前顶层、XPR、LCD XDC、旧 bit/gate 的备份：`vivado_project/logs/archive/acx750_before_hdmi_20261001`。旧 `acx750.bit` 仍是 TFT 镜像，不能误称 HDMI 新镜像。



## 验证结果（执行结束后补充）



已完成局部验证，不启动整机布局布线：



| 项目 | 实际结果 |

|---|---|

| 局部仿真 | EXIT 0，`PASS tb_hdmi_offline` |

| 原生光栅 | DE 614400，图像白色像素/取数各 384000 |

| 兼容光栅 | 800×480，取数/DE/RGB 与原驱动逐拍一致 |

| 按键 | 抖动过滤、0↔7、快捷键、同时按下优先级、长按不重复通过 |

| TMDS/时钟 | 4 个消隐控制码、串行控制码周期、差分互补、MMCM 锁定和 5:1 比例通过；尚未进行全像素颜色向量对拍 |

| HDMI 局部 OOC 综合 | EXIT 0，LUT 204、FF 172、BRAM/DSP 0、MMCM 1、BUFG 3、OSERDESE2 8 |

| 按键局部 OOC 综合 | LUT 90、FF 96、BRAM/DSP 0 |

| 局部综合时序 | HDMI WNS +15.901 ns、WHS -0.026 ns；按钮 WNS +6.930 ns、WHS +0.127 ns |

| 约束文本检查 | 活动 XDC 不含 LCD，显式引脚映射未发现重复，HDMI 引脚与厂商一致；不是实现后引脚 DRC 的替代 |

| 整机综合/路由/新 bit | 本轮未执行，旧 bit 仍属于 TFT，不覆盖新 HDMI 源码 |

| 上板 | 未验证；未操作当前不在手的板卡，未编程 Flash |



**OOC 不是最终时序签核。** HDMI 局部综合 WHS 有 -0.026 ns 的 8 个端点，需要整机实现后由真实布线验证/修复；不能将上述 WNS 当作整机路由通过。工具还提示 OOC 外部时钟未指定 `HD.CLK_SRC`，时钟插入延迟/偏斜估计有限。本轮未添加错误 false path 或降低 DRC。



证据：`vivado_project/logs/acx750_hdmi_sim_split_retry.log`、`acx750_hdmi_local_ooc_single.log`；详细资源/时序/控制集和 DCP 在 `vivado_project/logs/hdmi_local_synth/`。



局部综合脚本为 `tools/scripts/synth_acx750_hdmi_local.tcl`，包装顶层是 `acx750.srcs/sim_1/imports/sim/hdmi_ooc_top.sv`（仅综合验证，不是板级顶层）。未来先局部仿真/综合，再复用已有 IP 综合结果完成整机签核；普通局部 OOC 并不等于已建立 DFX 局部重配置或能单独烧入一部分 bit。



首轮整帧仿真一直运行高速 OSERDES/MMCM，耗时过长，因此终止该测试及所属 Vivado 进程，拆分为短时串行/时钟测试和低速整帧光栅测试；新测试完整通过，`run all` 约 24 秒。兼容模式初版垂直起点错误，仿真在第 27670 拍抓到，与原驱动的上下边沿对齐后通过。



两次局部综合启动分别遇到 realtime Tcl 和 Xilinx retarget Tcl 读取错误，均发生在综合子进程启动期间；局部工作目录隔离并设置 `synth.maxThreads=1` 后实际完成。通用工具线程仍为 16；本轮只能确认此重试组合成功，不能证明故障唯一原因。该局部流程的单线程设置不改整机的 16 线程构建。



## 到手后顺序



1. 断电接 HDMI；保持 JTAG、UART、电源，TFT 不再作为输出。先临时加载已通过门限的 HDMI 候选镜像，不写 Flash。

2. 验证彩条和显示器锁定；若原生时序不兼容，先采集型号/EDID，再选择兼容时序重新构建。

3. S1/S2 切换、S3 相机、S4 彩条；确认串口 S 字段与画面一致。

4. 以测试图验证 DDR 取数和颜色，再验证 OV5640 真图像、帧率、断流和复位。

5. 网络仍是独立未解决问题：厂商回环在同一布线通过 20/20，整合通信版接收活动 E 仍为 0。继续比较 RX MMCM 相位、PHY 配置与复位，不把线缆判定为已坏。

6. Full HDMI 接入必须由维护该工程的会话基于本轮测试证据实施，不能直接用通信版 bit 代替 Full。

---

<a id="doc-004"></a>

## 来源：Full存储结构优化_2026-10-02.md

# Full 存储结构优化与编译前审查（2026-10-02）



## 原始证据



Full 物理优化后 Slice 25,415/33,450（75.98%），LUT47,153，FF60,999，1,881控制集。Route出现35-447拥塞警告；已停止，保存布局/物理优化DCP和报告到 vivado_project/logs/archive/full_congestion_20261002。此数值是风险审查依据，不证明任意75%工程都不能布线。



综合层次：lidar_grid 10,095 LUT、12,745 FF，其中两个 cell_ram 已映射共52 RAMB36，队列另有BRAM；不是所有栅格数据都没有推断BRAM。



## 编译前结构审查与修改



文件：vivado_project/acx750_full/acx750_full.srcs/sources_1/imports/perception/lidar_grid.sv。



- visited：深3300、宽1，共3300bit；原FSM三处变量索引写（清零、种子、邻居），两个异步读。将互斥操作合并到单个写地址/数据/使能，独立无reset存储过程，distributed模板。顺序清空保留，预计LUTRAM替代FF与写解码网络。

- objects：深32、宽384，共12288bit；原排序移位与最终插入两处变量地址写，外部查询/排序比较/移位读为异步多地址读。合并互斥写到一个端口、独立无reset过程。用LUTRAM保留原异步接口，工具可能复制读存储；不盲目强制BRAM，因为同步读会改变排序和消费者时序。

- queue：3300×12同步读，原单写口BRAM保持；两bank cell_ram同步双口BRAM保持。此次不修改算法、门限、目标数、输出协议、扫描状态。

- 阵列不整体reset，visited仍逐格清零；objects由object_count定义有效区。reset禁止写入，已有无效旧内容不会成为合法输出。

- FSM阶段、单点吞吐、排序周期与输出延迟均不增加；没有新增跨时钟路径。新增写地址选择网络较小，代价由前后局部综合确认。



## 验证计划和发布限制



1. 修改前原始字节与模块重命名差分副本已归档；差分仿真逐周期比较握手、busy、计数、发布时间和计数器，发布时比较全部有效目标。

2. 覆盖超过32目标、排序移位、reset、角落/边界、稀疏目标、饱和、40000点溢出、3300格满连通域。

3. 同器件同配置前后OOC综合，读取FF、LUTRAM、BRAM、控制集和时序。局部综合资源下降不等于整机Slice一定下降。

4. 只有局部验证与整机结构预检查有量化依据后才恢复整机实现；当前没有新的Full候选bit。



编译/仿真均通过统一监控入口。结果尚待写入，不把预期推断写成通过。



## 本轮实际结果（已完成）



差分仿真EXIT0：844101周期、4次发布，目标记录与握手/发布时间一致；涵盖上述边界和溢出场景。前后同器件同参数OOC综合EXIT0，均无综合Error/Critical Warning。



| 指标 | 原版 | 优化版 |

|---|---:|---:|

| Slice LUT（包括LUTRAM） | 9991 | 3048 |

| FF | 12801 | 1443 |

| LUTRAM占用LUT | 212 | 840 |

| F7 / F8 MUX | 3441 / 588 | 106 / 2 |

| 控制集 | 295 | 71 |

| BRAM Tile | 53.5 | 53.5 |

| DSP | 17 | 17 |



**实际推断修正：原版visited已经用了LUTRAM，主要问题是objects排序表展开成FF和选择网络。** 修改后objects明确推断RAM32M；visited写口统一是模板明确化，不能把其原版误报成3300FF。LUT减少6943、FF减少11358、控制集减少224；不直接将局部差值相减当整机资源或Slice改善实测。



时序为综合估计，OOC时钟buffer位置未指定有Timing38-242提示，不是路由签核。测试和资源JSON位于results/full_grid_structure_20261002，保留before/afterDCP。第一次OOC工具启动读取unimacro_vhdl.tcl失败，尚未进入有效RTL综合；改用项目已有短临时目录方式后成功，失败日志也保留，不将启动错误归因于RTL。



尚未完成：整机新综合/打包及布局拥塞验证；畸变配置的7072位广播和active/shadow存储（C2）、目标发布宽总线（C3）、AR 32目标并行渲染仍需结构审核。当前不启动整机route，不声称Full新bit或上板通过。



局部综合100MHz估计WNS为+2.446→+1.671ns，资源改善伴随组合写口选择路径代价；均非路由时序。后续整机必须重新量化，不因资源下降放宽时序门限。



## 恢复完整构建前审查



C2：active/shadow畸变参数和7072位广播仍以寄存器保存，原接口要求全部参数同时可见/原子切换；必须一起重设计同步查表和提交所有权才可完全RAM化。本次保留其功能，不以删除标定表来降低资源；这是已知有界成本，不宣称已经优化完成。C3：网络目标宽发布及所有权仍保持原协议，未替换成不兼容串行接口。AR：32目标并行比较服务每拍1像素，当前MMCM像素51.25MHz；保留渲染吞吐和背压行为，避免未经验证降低目标数或时钟。



主要已修复根因：排序表不合理的FF/MUX展开。差分和实际推断已量化，决定进入整机综合验证该改动。新增physopt后的结构门：实际Slice≥70%触发人工结构审查并保存DCP；WNS低于-0.5ns阻止route。生成控制集、高扇出、拥塞和关键路径报告。70%仅审查触发线，不声称通用物理极限。不改时序约束，不降低最终WNS/WHS与DRC门限。



## 整机综合与布局实际结果（路由尚未签核）



整机含OOC IP综合：LUT41372、FF50158，grid3217LUT/1390FF，预检查WNS+0.874ns、Critical Warning0。



物理优化后：LUT39375、FF49539、Slice20114/33450=60.13%，控制集1631；相较旧检查点Slice减少5301，控制集减少250。WNS+0.110ns；拥塞报告无level5以上窗口。新增结构门通过，允许route；该阶段数字不是最终路由结果。



高扇出仍有全局reset25095、配置pending9153、projector LUT地址位1792等。旧接口C2/控制reset成本尚在，不能称全部网络已消除；路由若失败必须分析关键路径，不给这些网络随意false path。报告保存在Full impl_1的monitor_phys_*。



## 第二个根因：CRC决策长组合路径



首轮优化后route仍出现35-447，中间WNS-0.900/TNS-17.982，已停止并保存full_crc_path_20261002检查点。physopt实际路径parser/mem_reg→crc_byte→32bit比较→FSM→cx_reg/R共12级，逻辑3.853ns、估计布线5.458ns，共9.311ns。不能只降低Slice后重复route。



修改前已核对完整包缓存、CRC遍历、两种Cartesian拆包、ready/valid和scan除法时序。末字节CRC本来已有寄存器；新增state9在下一拍比较该寄存器，切断CRC计算到坐标复位的级联，不更改CRC公式、校验策略、点坐标或包格式。额外1个100MHz周期=10ns/包，逐点输出与背压机制保持。坏包计数/接收ready也相应晚1拍。没有新增CDC、大MUX或DSP，RAM读写模板保持，FSM增加1个状态。重新测试两种点型/坏CRC/零CRC/结构错误后才再综合。



CRC新版本两种点型、CRC拒收/零CRC/结构错误及周期性背压稳定性测试均EXIT0，日志full_crc_backpressure_test.log。局部OOC两次在进入RTL综合前读取rtSynthParallelPrep.tcl失败；该文件Windows侧确实存在，单线程也未解决，不能认定线程数是根因。不把此步骤标通过；改用已能正常执行的整机launch_runs流程检查真实资源和时序。



为减少Explore重复优化耗时，本次Full使用Route Default，仍开启physopt AggressiveExplore与原频率，所有最终时序/DRC门限不变；失败仍按路径修RTL，不通过降频或放宽约束获得bit。只改变工具搜索努力，不改变RTL延迟/协议。



## 2026-10-02 最终状态



Full候选bit已生成并核验：WNS+0.079ns、WHS+0.034ns、DRC_BAD0；最终LUT39398、FF49603、Slice59.90%、控制集1635。路由8分39秒。资源/CRC长路径修复后完成本轮离线交付，真实硬件、残留CDC/RDC警告及C2/C3未完成，工具内部脚本读取问题根因未确认。详见双工程HDMI候选bit验收_2026-10-02.md；前文失败/进行中描述保留为试错历史。

---

<a id="doc-005"></a>

## 来源：HDMI工程标准结构整理_2026-10-02.md

# HDMI 工程标准结构整理

## 当前入口

直接在 Vivado 2020.2 中用 Open Project 打开：

- `vivado_project/acx750/acx750.xpr`：通信版，含 HDMI。
- `vivado_project/acx750_full/acx750_full.xpr`：Full 版，含 HDMI。
- `vivado_project/acx750_hdmi_bringup/acx750_hdmi_bringup.xpr`：独立彩条测试。

后续只修改以上工程自己的 `.srcs` 源文件。旧工程、归档、source_snapshot 不作为活动源码入口。

## 实际修改

两套整机本来就是 Vivado 原生项目模式工程，具有 `.xpr`、`.srcs`、`.runs`、`.cache`、`.hw`、`.sim` 和 `.ip_user_files`。这次没有重建整机，也没有修改 RTL、XDC、频率或已有实现结果。

独立彩条工程原来嵌套了一层同名目录，且引用外部 `rtl/constrs`。已使用 Vivado `create_project` 和 `import_files` 重新建立：

```text
acx750_hdmi_bringup/
  acx750_hdmi_bringup.xpr
  acx750_hdmi_bringup.srcs/
    sources_1/imports/...
    constrs_1/imports/...
  acx750_hdmi_bringup.cache/
  acx750_hdmi_bringup.hw/
  acx750_hdmi_bringup.ip_user_files/
```

`synth_1` 和 `impl_1` 已建立；`.runs`、`.sim` 等目录由 Vivado 在实际运行相应步骤时生成，不建立空目录伪装编译结果。

彩条构建脚本 `tools/scripts/build_hdmi_bringup.tcl` 改为打开现有 `.xpr`，使用 `launch_runs/wait_on_run/open_run`，不再强制创建嵌套工程或绕过项目运行系统。保留原有时序门限。此脚本的新构建流程尚未实际重新综合/布线。

两套整机根目录的日志、报告、审计表和 WebTalk 文件已移动到：

`vivado_project/logs/archive/hdmi_layout_20261002_153909/`

其中也保留原彩条整个目录与两套整机修改前的 XPR。工程根目录保留 XPR、bit、bit_gate.json 和 Vivado 原生目录。Vivado GUI 打开时仍可能生成自己的 .log/.jou，不能随意移动活动运行的日志；批处理入口继续把工作目录设在 `vivado_project/logs`。

## 已验证与边界

Vivado 2020.2 实际打开三套 XPR、更新编译顺序，检查所有引用文件存在且位于各自工程内，并确认 synth_1/impl_1 存在。结果：

| 工程 | 文件数 | synth_1 | impl_1 |
|---|---:|---|---|
| acx750 | 276 | synth_design Complete | route_design Complete |
| acx750_full | 305 | synth_design Complete | route_design Complete |
| acx750_hdmi_bringup | 6 | Not started | Not started |

检查退出码 0。证据：`vivado_project/logs/hdmi_project_structure.tsv` 和 `hdmi_standard_layout.log`。工具提示尚未生成的 `.gen/sources_1` 目录，未发现缺失活动源文件。

两套整机 bit 的 SHA256 未变化，`check_hdmi_candidate.py` 两项检查再次通过；因此继续使用此前候选镜像。彩条根目录 bit 是原有镜像保留副本，不是此次新生成，不能把新工程 Not started 写成综合或板测通过。

此次仅整理结构和验证项目加载，没有重新编译整机，也没有下载至板卡。

## 后续维护

- 开发入口为以上 XPR 和 `.srcs`，不得重新回到旧的外部 RTL 目录。
- 新增设计文件用 Vivado Add/Import Sources，约束加入 constrs_1，检查复制到项目内。
- HDL/XDC 继续使用 GBK/CP936 无 BOM；Python/Tcl/Markdown 使用 UTF-8 无 BOM。
- 编译仍先执行结构审查，再使用统一监视器入口；保留时序、DRC、源码和 bit 哈希门限。
- 目前下一步仍是候选镜像上板验证，目录检查不是硬件验证。

---

<a id="doc-006"></a>

## 来源：HDMI迁移交接_2026-10-01.md

# TFT → HDMI 迁移交接（2026-10-01）

> **本轮状态：最小 HDMI 彩条 bring-up 工程已建、已综合、已实现、已出 bit。未上板验证；整机（acx750_full）尚未改造。**

## 1. 背景与用户决定

- 板卡 **TFT 接口硬件已损坏**，用户要求改用 HDMI 输出。
- 用户确认两项方案：
  1. **5× 像素时钟用「新增第二 MMCM」**（不改已验证的 `clk_sys_wiz`）。
  2. **先出最小 HDMI 彩条 bit 上板验证硬件通路**，通过后再改整机。

## 2. 硬件可行性核查（已完成，有依据）

- 整板权威约束 `ACX750例程\盘A_ACX750开发板标准配套资料\04_引脚功能信息\ACX750_CB_PIN.xdc` 中明确有 HDMI TX：
  | 信号 | 球号 |
  |---|---|
  | HDMI_CLK_P / _N | J19 / H19 |
  | HDMI_D0_P / _N | K21 / K22 |
  | HDMI_D1_P / _N | J20 / J21 |
  | HDMI_D2_P / _N | J22 / H22 |
  | HDMI_OE | M22 |
  | HDMI_HPD / SCL / SDA | N22 / L20 / L19 |
- 我方 `clk50m = W19`、`btn_reset_n = D21`，与厂商 ch26 例程（`clk50M=W19`、`reset_n=D21`）**完全一致**。
- 厂商 `ch26_acx750_rom_image_tft_hdmi` 例程器件为 **xc7a200tfbg484-2**，与我方完全相同，并且**自带一个已综合好的 `.bit`**：
  `ACX750例程_解包\ch26_acx750_rom_image_tft_hdmi800x480\...\acx750_rom_image_tft_hdmi\bit\rom_image_tft_hdmi.bit`
  → 可作为**零构建成本的硬件判定**（尚未编程，需用户决定）。

## 3. 关键约束：为什么必须第二个 MMCM

- 整机现有 `clk_sys_wiz`：输入 50 MHz，VCO = 1200 MHz，输出 200 / 100 / **33.333** / 24 MHz。
- TMDS 串行器需要 **5 × 像素时钟 = 166.667 MHz**；`1200 / 166.667 = 7.2`，**不是整数分频**，MMCM 的 CLKOUT0 分数分频粒度 0.125 也无法表示 7.2。
- 穷举后：不存在能同时整数分频出 200 / 100 / 24 / 33.333 / 166.667 的 VCO（需同时是 200、24 的倍数且能除出 166.667，仅 600/1200 满足前者，两者都除不出 166.667）。
- 因此采用：**第二个 MMCM，输入取 `clk_pix`（已 BUFG），VCO = 1000 MHz，/6 → 166.667 MHz**。此方案不动 `clk_sys_wiz`，相机 XCLK 保持精确 24 MHz。
- 最小 bring-up 里等效实现为单个 MMCM（50 MHz 输入，VCO=1000，/6=166.667、/30=33.333），因为 bring-up 不需要 200/100/24。

## 4. 本轮新增文件

工程目录：`vivado_project/acx750_hdmi_bringup/`（**新工程，两个已验证工程 `acx750` / `acx750_full` 未改动**）

| 文件 | 说明 |
|---|---|
| `rtl/acx750_hdmi_bringup_top.sv` | 顶层：MMCME2_BASE(VCO=1000) + 3×BUFG + 彩条 + TMDS 编码器；`hdmi_oe=1` |
| `rtl/acx750_hdmi_colorbar.sv` | 800×480 光栅 + 8 条彩条；H_TOTAL=1056、V_TOTAL=525，HS/VS **低有效**（与厂商 ch26 极性一致） |
| `rtl/vendor_ref/dvi_encoder.v` | 厂商原文件，**按字节拷贝，一字未改** |
| `rtl/vendor_ref/encode.v` | 同上 |
| `rtl/vendor_ref/serdes_4b_10to1.v` | 同上（ODDR+OBUFDS 10:1 串行器） |
| `constrs/acx750_hdmi_bringup.xdc` | clk50m/reset/HDMI 管脚、TMDS_33、`create_clock`、`UNUSEDPIN Pullnone`、reset false_path |
| `tools/scripts/build_hdmi_bringup.tcl` | 统一入口构建脚本，**带时序门限** |

厂商文件拷贝哈希（SHA256，用于核对未被改动）：
- `dvi_encoder.v` `ED3A59442E13696A35F2C1BF273728E7D93AD01A5B0D9320F0094FE67AAA700F`
- `encode.v` `47FB075BB48D619A3A2A802B9935B2C3C352B2DE109A3895773E906582EDB279`
- `serdes_4b_10to1.v` `193FAF53B9674B42338D6FFE75466132D39153DA0F1E6814811CC9CF8210A810`

**编码说明**：新增 HDL/XDC 全部使用**纯 ASCII 注释**（ASCII 同时是合法 GBK），避免中文注释被写成 UTF-8 破坏项目「HDL 为 GBK/CP936 无 BOM」约定；厂商文件按字节拷贝，编码未变。

## 5. 构建门限（落实「构建前先查时序」）

`build_hdmi_bringup.tcl` 的分段门限，全部在**实现前**拦截：

1. `synth_design` → `report_utilization` / `report_timing_summary` / `report_drc`
   - **WNS < 0 或 Critical Warning > 0 → exit 1，不进 place/route**
2. `opt_design` → `place_design` → `route_design` → 报 timing/DRC/utilization
   - **路由后 WNS < 0 或 WHS < 0 或 Critical Warning > 0 → exit 1，不写 bit**
3. 通过后才 `write_bitstream`

## 6. 本轮实测结果（全部读自真实报告，不是日志猜测）

构建入口：`tools/run_build.py --name hdmi_bringup --kind vivado`，退出码 **0**。

| 项目 | 结果 | 证据 |
|---|---|---|
| 综合 WNS | **+3.853 ns**，Critical Warning 0 | 构建日志 `=== HDMI BRINGUP: synth WNS ...`；`synth_timing.rpt` |
| 路由 WNS | **+3.757 ns** | `routed_timing.rpt` |
| 路由 WHS | **+0.126 ns** | `routed_timing.rpt` |
| 失败端点数 | 各时钟域 **0**（TNS/THS 均为 0） | `routed_timing.rpt` |
| 时钟 | `clk50m` 20.000 ns；`pix_clk5x_raw` **6.000 ns = 166.667 MHz**；`pix_clk_raw` **30.000 ns = 33.333 MHz**；未连接时钟源 0 个 | `routed_timing.rpt` Clock Summary |
| 跨域路径 | `pix_clk_raw → pix_clk5x_raw`（编码器→串行器）WNS **+3.757**、WHS **+0.126**、0 失败 | `routed_timing.rpt` Inter-Clock |
| DRC | **1 条，CFGBVS-1 Warning**（缺 CFGBVS/CONFIG_VOLTAGE 属性），**无 Error / 无 Critical Warning** | `routed_drc.rpt` / `synth_drc.rpt` |
| 资源 | Slice LUT **107**、FF **113**、Slice 43、BUFG 3、MMCM 1、IOB 11 | `routed_utilization.rpt` |
| bit | `vivado_project/acx750_hdmi_bringup/acx750_hdmi_bringup.bit`（9,730,772 B） | 文件系统 |
| bit SHA256 | `E64E4889E60E115CA0481E41990550792257C11B0D247FCC806ABA43B44E6134` | `Get-FileHash` |

> CFGBVS-1 是设置属性缺失的提示，不是布线/功能错误；整机 `acx750_full` 目前同样未设置该属性，故保持一致，未擅自新增。

## 7. 五档验收口径（严格区分）

| 环节 | 状态 |
|---|---|
| 源码已写 | ✅ 新增 2 个 RTL + 1 XDC + 1 Tcl；厂商 TMDS 三件套按字节拷贝 |
| **仿真通过** | ❌ **未做**（彩条光栅模块尚无 testbench，未跑 xsim） |
| 综合通过 | ✅ WNS +3.853，Critical Warning 0 |
| 实现/路由通过 | ✅ WNS +3.757 / WHS +0.126，0 失败端点，DRC 无 Error |
| 出 bit | ✅ 已生成（哈希见上） |
| **板上通过** | ❌ **未验证**（未编程、未接显示器） |

**结论：当前只能说「出了一个时序合格的候选 bit」，不能称 HDMI 已工作。**

## 8. 未完成的项（按优先级）

1. **上板验证**：把 `acx750_hdmi_bringup.bit` 烧进板子，接显示器看 8 条彩条。
   - 更省事的前置判定：先烧厂商 ch26 现成 bit（器件/时钟管脚/HDMI 管脚全对），几秒判定硬件好坏。
   - 注意：项目有「JTAG 加载新 bit 后 rebind 导致卡死」的历史记录，烧录前按既有安全前置检查执行，不擅自动手。
2. **补仿真**：给 `acx750_hdmi_colorbar.sv` 加 TB，校验每行 DE=800、每帧 480 行、HS 128 像素低有效、VS 2 行低有效、帧周期 1056×525。
3. **整机改造（acx750_full）**，尚未开始：
   - 注释掉 TFT 输出：`acx750_lcd.xdc` 的 21 条 TFT 管脚约束、顶层的 `tft_*` 端口（保留 `disp_driver` 作为时序发生器）。
   - 把 `disp_driver` 的 HS/VS/DE + RGB565 转 RGB888（`{rgb[15:11],3'b0}` / `{rgb[10:5],2'b0}` / `{rgb[4:0],3'b0}`）送进 TMDS 编码器。
   - 新增第二个 MMCM（输入 `clk_pix`，VCO=1000，/6=166.667）。
   - 新增 HDMI 管脚/约束，删除 TFT 管脚约束。
4. **⚠ 整机显示时序必须先复核**：整机光栅由厂商 `disp_driver` 产生，但 `disp_parameter_cfg.v` 里出现 `H_Total_Time = 12'd1650`，与显示器能锁的 1056×525 **不是一套数**。接 HDMI 前必须先把整机实际 H/V total 查清并改到标准 800×480 时序，否则编码器和时序都对、显示器仍不锁。
5. 整机改造后仍需：整机综合预检查 → 布局 packing/拥塞检查 → 路由 WNS/WHS≥0 + DRC/CDC → 才生成候选 bit；随后真实相机/AR 上板验收。

## 9. 边界与不可混用

- 本轮的 WNS/WHS 是**最小彩条工程**的，**不能**当作整机 `acx750_full` 的时序结论。
- 本轮**未**修改 `acx750` / `acx750_full` 任何文件；`fpga_acx750`、旧工程、`source_snapshot`、厂商原工程均未改动。
- 未做 git 提交/推送。
- 厂商 ch26 的现成 bit 是**厂商产物**，只能作硬件通路判定，不代表我方 RTL 通过。

---

<a id="doc-007"></a>

## 来源：MIGRATION_HANDOFF.md

> **2026-10-01 最新硬件决定：AC880/7020 已退出项目，不再修复、构建或上板；以后只使用 ACX750/7A200T。AC880 文件仅保留历史参考。当前两套 750 待办见 [ACX750待办清单](01_项目方案与联调指南.md#doc-001)。**





> **2026-10-01 目录规则更新：** 全部项目 Markdown 集中到 `docs`，根目录只保留 `README.md` 材料索引。后续按用户整理后的结构工作；当前路径、启动入口及遗留问题见 [目录与材料索引说明](01_项目方案与联调指南.md#doc-004)。FPGA 只修改 `vivado_project` 新工程，上位机在 `web_server`，前端在 `user_app`；不修改旧项目。



# 新工程迁移交接



## 后续修改规则（必须遵守）



**后续开发、约束修改、IP配置、仿真和构建，以本目录下的三个标准Vivado工程为唯一工作入口。不要再修改旧的 `fpga_ac880`、`fpga_acx750`、`fpga_acx750_full`。**



旧目录保留作来源与历史回归参考；`source_snapshot` 是迁移时的冻结快照，也不作为日常编辑入口。RTL、约束、测试文件通过Vivado Sources编辑，实际文件在各工程的 `.srcs` 内；IP通过Customize IP修改。



## 工程



- ac880/ac880.xpr：XC7Z020CLG484-2，sensor_perception_ar_top，感知AR整机。

- acx750/acx750.xpr：XC7A200TFBG484-2，acx750_top，平台基线。

- acx750_full/acx750_full.xpr：XC7A200TFBG484-2，acx750_full_top，感知AR集成。



由本机Vivado 2020.2生成。三个工程包含sources_1、constrs_1、sim_1及真实IP，未使用测试桩冒充IP。源码校验记录见source_manifest.json。



## 打开与构建



直接双击对应xpr，或在本目录PowerShell执行：



```powershell

.\run_vivado.ps1 -Project acx750_full -Action Open

.\run_vivado.ps1 -Project acx750_full -Action Validate

.\run_vivado.ps1 -Project acx750_full -Action Implement

```



Validate运行选定仿真与综合。Implement运行布局布线、生成时序/DRC/资源报告；WNS/WHS均非负且没有Error/Critical Warning才输出bit。请以MIG校准、真实设备与板测为最终硬件验收，不以工程打开或综合通过代替。



## 官方资料与下载



已阅读配套ACX750用户手册V1.1的器件、存储器及JTAG连接章节。ACX750-200T器件为XC7A200TFBG484-2，板载50MHz晶振，2片MT41K256M16，32位1GB DDR3；MIG辅助配置使用ACX750的ch57 32bit原例程，未使用AC880 DDR配置。



ACX750通过Platform Cable连接JTAG，板载USB转串口不是下载器。AC880保持既有XC7Z020CLG484-2与已核对的板卡约束。首轮只用Hardware Manager临时Program Device，先核对识别的器件型号再选择本次通过门限的bit；不写QSPI/SD/eMMC。当前没有执行任何上板下载。



## 迁移修复



- 厂商2018.3 IP在2020.2中升级并生成真实输出文件。

- 每个IP独立输出目录；修复复制脚本把其他xci带入MIG目录引起的Shared output directory锁定。

- 复制mig_a.prj/mig_b.prj，保留官方板卡DDR引脚参数。

- AC880重新建立PS Block Design，导入实际RTL与有效约束；自定义IP仓库保存在新工程内。

- 读取2026-10-01今晚更新的项目总交接及ACX750 full最终状态，纳入底盘A15/A16等最新源码；原工程不改。



## 验收结果



详见MIGRATION_STATUS.md与各工程的报告和本目录日志。bit是否存在及能否作为候选，由本次实现门限决定；尚未做板级验证。

## 编码规则（2026-10-01，必须遵守）



- 本机Windows + Vivado 2020.2内置编辑器：人工维护的RTL（.v/.sv/.vh/.svh）和XDC统一采用 **GBK / Windows代码页936，无BOM**，让中文注释在内置编辑器中正确显示。

- Markdown、JSON、Python统一UTF-8无BOM；含中文的PowerShell脚本用UTF-8 BOM，兼容Windows PowerShell 5.1。Vivado Tcl脚本优先ASCII代码与英文注释，必要中文采用UTF-8，并避免把编码不确定的文本写入命令参数。

- Vivado自动生成的IP、BD、wrapper等产物不手动转码；厂商来源快照保持原始字节。只在新工程的人工维护源文件中处理编码。

- 写文件时明确指定编码，不依赖PowerShell版本的Default/UTF8默认行为。代码页936示例：`[IO.File]::WriteAllText($path,$text,[Text.Encoding]::GetEncoding(936))`。

- 本轮转换报告在encoding_conversion.json，已核对有效代码字符不变；GBK不能表示的装饰符仅在注释内移除。编码转换可能让GUI中的运行状态显示Out-of-date，必须重新构建后再判断。

- 已打开的编辑器标签请关闭后重新打开；不要用旧标签中的乱码内容覆盖新文件。

迁移后还提供 `program_jtag.tcl`，仅允许存在本次时序/DRC门限记录的bit，通过JTAG临时加载；核对JTAG目标唯一且识别器件与工程一致。不调用program_flash，不写非易失存储。该脚本本轮没有对真实硬件运行。

## 重建脚本边界



create_ac*.tcl只用于首次创建或在空目录恢复冻结的迁移快照，已存在的工程会拒绝覆盖；日常使用run_vivado.ps1即可，不能重新运行prepare_migration.py覆盖快照。迁移修复保存在apply_migration_fixes.py（RTL/约束）与fix_clocking.tcl（真实时钟IP/OOC缓存）。恢复时必须应用修复再构建；旧快照仅用于复现来源，不取代新工程后续修改。

---

<a id="doc-008"></a>

## 来源：Route_Design专项审计_2026-10-01.md

# Route Design 性能问题报告

日期：2026-10-01。对象：`vivado_project/acx750` 与 `vivado_project/acx750_full`，Vivado 2020.2，XC7A200T-FBG484-2。

本轮只读工程输入，新增审计工具/报告/文档。没有修改RTL、XDC、XPR或构建策略，没有综合、布局、布线或生成bit；只打开已有物理优化DCP提取报告。上一轮full布线由用户人工停止，不能写成自然完成失败。

## 1. 总体判断

### 最可能的三个原因

1. **大量存储被实现成FF及控制/选择网络，Slice装箱压力远高于LUT百分比。** `perception_regs`综合占30,464 FF、9,159 LUT，没有BRAM/LUTRAM；物理优化后整机Slice占94.87%，LUT只占41.39%，control sets达到3,861。原始数组读写方式直接解释这一结构风险。
2. **超宽结果/畸变接口后接动态MUX，地址和控制传播到多个模块。** 7,072bit LUT、4,128bit目标payload、384bit对象动态读；实际地址网扇出1,792，最差配置读回和目标捕获路径主要耗时在连线。
3. **小缓存RAM推断失败和多地址并写，放大每字节CE、译码和读MUX。** 雷达/配置FIFO、栅格位图和距离缓存明确被综合器溶成寄存器；发送缓存虽没有reset，CRC四地址同时写仍不适合普通单写RAM。

这是证据支持的优先级，不是已证明每项各自贡献多少分钟。没有优化后A/B构建，不能承诺提速比例。当前也没有完整路由结果，不能判断最终可布通性。

### 各阶段证据分开看

| 阶段 | 工具命令elapsed／资源／时序 | 来源 |
|---|---|---|
| 综合 | 3分54秒；LUT57,117，标准报告Flip-Flop90,576，层级报告FF列90,590；BRAM63.5 tiles；DSP76 | `acx750_full.runs/synth_1/runme.log`、综合报告 |
| 布局 | 8分39秒；最差-0.906ns，目标捕获路径，80.343%为估算连线延迟；control sets3,826 | 布局日志/关键路径/control sets |
| 布局后物理优化 | 14分11秒；LUT55,374/41.39%，Slice31,733/33,450=94.87%；Flip-Flop90,014；control sets3,861；WNS-0.352ns | physopt DCP独立报告 |
| 路由中途 | 日志累计38分24秒时仍在rip-up/reroute；重叠节点34,467→7,361；WNS-1.791ns/TNS-2721.109ns；Route35-447报告拥塞 | 人工停止前的impl日志 |
| 基础版既有结果 | routed层级LUT13,216、FF15,703；此前候选WNS+0.705ns/WHS+0.028ns | 基础版既有路由报告；不是本轮重建 |

标准资源报告和层级FF列统计口径不同，不将90,590当标准Flip-Flop数量。`report_ram_utilization`还计入MIG的7个OUT_FIFO、4个IN_FIFO，显示74.5；普通BRAM仍是60 RAMB36+7 RAMB18=63.5 tiles，不能混用。

工具命令elapsed与监视器按阶段时间戳计算的耗时可不同：后者还包括阶段报告及hook。这里不把单命令耗时当整轮构建时间，也不按源代码行数推算编译速度。

### 检查覆盖和边界

- acx750读取225个RTL：直接Design导入43、Simulation导入6、生成/厂商IP171、其余5。
- full读取258个RTL：直接Design导入63、Simulation导入14、生成/厂商IP171、其余10。
- 合计483份`.v/.sv/.vh/.svh`；106份直接Design路径去重为64份内容，42份在两个工程共享。候选模式扫描覆盖所有文件，人工硬件结构分析重点覆盖直接设计源和实际综合实例。
- 厂商IP按配置、综合层级及RAM报告汇总，没有把生成副本、simulation模型或每个原语声明当成一个待改问题。
- full静态未触达的`acx750_top`、`acx750_m3tl_tx`、`eth_udp_rx_gmii`不归因于当前full硬件。静态实例扫描不代替综合层次；头文件虽无module，仍被include使用。
- 模式命中不是问题数量；变量索引、for、generate、常量运算必须结合推断和实际硬件判断。
- 新报告位于`results/route_audit_20261001/full_physopt`；覆盖和审计前550份输入SHA256在`coverage.json`。

下文源码路径默认相对full的`acx750_full.srcs/sources_1/imports`；共享项同时适用于基础版对应imports。行号是本轮读取的活动源码。

## 2. Critical 问题

### C1：快照/配置数组成为大寄存器阵列与动态读取网络【已证实】

**文件／模块／位置：** `perception/perception_regs.sv`，`perception_regs`，25–26、39–44、58–60、69–78。

```systemverilog
logic [31:0] shadow[0:63], cfg[0:63];
logic [31:0] lut_shadow[0:220], lut[0:220];
logic [31:0] snapshot[0:415];
for(j=0;j<416;j=j+1) snapshot[j] <= 0;
for(j=0;j<221;j=j+1) lut[j] <= lut_shadow[j];
s_axi_rdata <= snapshot[(s_axi_araddr-12'h800)>>2];
for(j=0;j<12;j=j+1)
  snapshot[32+copy_index*12+j] <= object_data[(11-j)*32+:32];
```

**问题／硬件：** 名义存储31,552bit，整片清零/复制、32个metadata字同拍写、12个对象字同拍写；形成FF阵列、字/字节CE、译码网络以及约416:1/221:1的32bit读取MUX。输出端加寄存器并不使背后的任意多写存储自动成为BRAM。

**为什么影响routing：** 小粒度控制集合使FF分散；地址与数据选路横跨对象读出、快照和目标封装。综合9,159LUT/30,464FF；物理优化9,189LUT/30,474FF，无RAM。放置路径从`copy_index`到`payload_b[140]/S`有7级逻辑、8.252ns估算连线延迟，途经扇出1,408的对象选择网。路径走过X123Y46→X128Y15→X76Y68→X26Y71，已出现空间跨度。

**建议修改：** 快照采用有明确读写端口的384bit对象记录RAM及metadata存储，保留一对象/拍捕获；AXI只从一个已读出的记录选一个32bit字段。控制与RAM数据reset分离，保留seq/busy和初始化可见语义。普通32bit单口串行替换要416次写，会改变snapshot_busy/index节奏，不能当直接替换。

**延迟／吞吐：** 同步AXI读取预计+1–2个100MHz周期（10–20ns），RVALID/RDATA一起延迟并在背压下保持；宽记录分bank可维持一对象/拍。若选择单字串行写，必须明确额外写周期及目标旁路调整。双缓冲“只读上一份完整结果”会改变当前busy期间读可见性，不能默认作为行为相同的优化。

### C2：畸变表全量导出后接221:1选择器【已证实】

**文件／模块／位置：** `perception_regs.sv`21/34/60；`perception_engine.sv`55；`fixed_projector.sv`33–37/75–87。

```systemverilog
output logic [7071:0] lut_words;
generate for(genvar g=0;g<221;g=g+1)
  assign lut_words[g*32+:32]=lut[g]; endgenerate
assign lut_sample = lut[lut_index*32+:32];
lut_index = ly*17+lx+(sample[0]?1:0)+(sample[1]?17:0);
```

**问题／硬件：** 221个32bit字全量并行导出，然后仅选一个。产生221:1字选择树、跨模块7,072bit线路、地址广播；提交时还整片复制active/shadow表。

**为什么影响routing：** DCP实际`lut_index[0/1]`各驱动1,792负载，`[2]`驱动864；相关slack为负。`gy→地址/选择→LUT→DSP`路径10级，估算连线7.317ns/75.286%。配置提交网还驱动7,080负载，但该网当前slack+0.911ns，不能把高扇出自动等同于当前时序失败。

**建议修改：** 使用221×32同步读RAM的active/shadow bank，投影以`read_addr/read_valid/read_data`访问；增加响应sample索引流水线。保留默认零畸变、部分写、config_safe提交和切换后shadow内容一致性。bank交换后下一轮部分更新不能从过时的shadow开始；需要准备/镜像/复制机制并对外反映busy。

**延迟／吞吐：** 四角LUT采样维持一字/拍II=1，充分预取时每物体角点只增加一个启动周期。32目标×8角×10ns=2.56µs/满批次是该调度的预算；逐字等待会更大，必须仿真确认。像素吞吐不变，不增加整帧等待。

### C3：目标payload多字节并写＋4,128位跨模块选择【已证实】

**文件／模块／位置：** `eth/acx750_m3tl_targets.sv`57、133、193–210、266–267、301–303；`eth/acx750_m3tl_full_tx.sv`115/400。

```systemverilog
logic [7:0] payload_b[0:515];
payload_b[4+snapshot_index*16+2] <= w_x0[7:0]; // 同拍另写13个字节
assign tgt_payload[g*8+:8] = payload_b[g];
pay_b = tgt_payload[pay_i[9:0]*8+:8];
```

**问题／硬件：** 14个目标字节同时写，sqrt结束又同时写两字节；所有字节导出为4,128bit，接约516:1字节MUX。常量字节可能被裁剪，因此516:1描述的是RTL等效选择规模，不是逐门精确数量。

**为什么影响routing：** 目标模块综合1,603LUT/4,946FF，无RAM；快照选择、sat16封装、payload写译码串联，已位于真实负时序路径。物理优化后snapshot_busy→payload仍有约79–80%连线延迟。

**建议修改：** 128bit/目标记录RAM，先寄存截断/饱和后的目标及索引，再写记录；通过地址读响应向发送端提供字节/记录，删除4,128bit接口。距离两字节可单独小表或record读改写；header单独少量寄存器。保留当前记录顺序、sat16、CRC、count/overflow、序号和ack时机。

**延迟／吞吐：** 捕获流水级+1拍10ns，但仍一目标/拍；必须在最后一条延迟写完成后进入sqrt/发布。RAM发送增加首字预取1拍，预取/保持可维持一字节/125MHz周期；如果简单每字节等待一拍会降低吞吐，不能作为默认方案。

## 3. High 问题

### H1：雷达与配置异步FIFO数据溶成FF【已证实】

**文件／模块／位置：** `eth/acx750_radar_stream.sv`51、94–114、148–150；实例`u_radar_stream`与`u_cfg_stream`。

```systemverilog
(* ram_style="distributed" *) logic [8:0] mem[0:511];
always_ff @(posedge eth_clk or negedge eth_rst_n) begin
  if(!eth_rst_n) begin /* 指针/状态复位 */ end
  else if(wr_en && !full) mem[wbin[8:0]] <= {wr_last,d_d};
end
assign radar_data = mem[rbin[8:0]][7:0];
```

**问题／硬件／routing：** 没有数组清零赋值，但memory写处于异步reset敏感进程，2020.2综合日志594–595明确说明不支持并溶成寄存器。两个实例各4,608bit存储；综合约1,841/1,843LUT和4,785/4,818FF，零RAM，带来512字写CE和异步读MUX。

**建议／延迟：** RAM写独立纯posedge进程，指针、full和CDC状态保留复位；先保持合法LUTRAM异步读/FWFT接口，预算零附加读取周期。若改BRAM/XPM必须实现预取、协调复位和首字valid，至少新增首字读取周期但维持一字节/拍。不能只改属性。

### H2：413字节栅格读出缓存RAM失败【已证实】

**文件／模块／位置：** `perception/acx750_grid_reader.sv`55/74/79/107，`acx750_grid_reader`。

```systemverilog
logic [7:0] sbyte[0:412];
assign byte_out = sbyte[bidx];
// sbyte写入在带negedge rst_n的FSM进程中
```

**问题／硬件／routing：** 3,304bit数据变FF及413:1字节MUX，综合1,539LUT/3,373FF，无RAM；日志673–674确认推断失败。DCP`bidx[1]`扇出1,010，当前正裕量，属于资源/拥塞负担而非当前最差路径。

**建议／延迟：** 存储写与FSM复位分离，保留LUTRAM异步读则无需附加周期；bidx可从16缩9bit，对外zero extend。若同步读则byte/index/valid同步增加1拍，并修改第一字和结束条件。8bit `1<<bitpos`不是超宽移位热点。

### H3：发送frame_buf同拍四地址CRC写＋异步读【已证实】

**文件／模块／位置：** full `eth/acx750_m3tl_full_tx.sv`238、645–669、677；基础版`eth/acx750_m3tl_tx.sv`139、398–415、426。

```systemverilog
frame_buf[24] <= crc_result[7:0];
frame_buf[25] <= crc_result[15:8];
frame_buf[26] <= crc_result[23:16];
frame_buf[27] <= crc_result[31:24];
assign tx_payload = frame_buf[idx];
```

**问题／硬件／routing：** data写进程已无reset；同拍四写、动态header/payload写与异步读取导致每字节使能及大MUX。full综合5,135FF；基础版4,443FF，两者均无BRAM。full的84LUTRAM还包含grid_buf，不能把模块所有存储统称FF，也不能将模块FF当单数组精确值。

**建议／延迟：** 32byte header/CRC保留小寄存器，payload独立单写RAM；CRC寄存器无需在数据RAM四地址patch。发送预取RAM数据，header与payload按序拼接。125MHz首字额外1拍8ns，稳态一字节/拍。若使用CRC串行回写替代四写，则每次四字写比原来增加3拍，两次CRC共6拍48ns，必须计入准备阶段。不要靠放松CRC路径约束。

### H4：32×384对象数组有多个异步读出口【部分网表证实，单数组FF计数待定】

**文件／模块／位置：** `perception/lidar_grid.sv`37、63–67、203–210，`lidar_grid`。

```systemverilog
object_t objects[0:31];
assign object_data = objects[object_index];
before_object(region,objects[insert_index]);
objects[move_index] <= objects[move_index-1];
```

**问题／硬件／routing：** 名义12,288bit，多套32:1宽读MUX和动态排序写。没有整数组reset，但不等于RAM成功；实际RAM映射没有objects，grid自身FF约12,749且布局路径穿过对象选择网络。不能把全部grid FF精确归为objects。

**建议／延迟：** 合并写端口、仲裁读地址、同步读记录并加object_valid；排序比较、移位、投影和snapshot均要适配。新读周期+1拍10ns，若不能隐藏，排序每次比较/移动均额外一拍。32目标插入/移动最坏预算单独验证，不只算32次对外读取。32:1低位索引小不代表384bit读网络小。

### H5：配置请求组合地址直穿快照大MUX【已证实】

**文件／模块／位置：** `eth/acx750_cfg_bridge.sv`174–188及AXI地址输出；`perception_regs.sv`64–71。

```systemverilog
grp_off = 7'(8'd4 + grp_idx[3:0]*stride);
cur_widx = {pkt_buf[grp_off+1],pkt_buf[grp_off]};
// 同一条组合路径继续形成ARADDR及大型RDATA选择
```

**问题／硬件／routing：** 128byte pkt_buf约6路变量byte读取，stride→地址→包MUX→寄存器页MUX跨模块串联。当前physopt最差grp_idx→RDATA，-0.352ns、12级、7.890ns估算连线/76.766%；其他stride路径14级。派生配置控制网有943/933/929负载。

**建议／延迟：** 增加请求准备寄存器，在发AW/AR/W前锁住地址、数据和strobe；响应独立RAM流水线。100MHz请求准备每次+1拍10ns，416字快照批次的请求准备增量为4.16µs；这是仅请求侧预算，不含C1的RAM读取+1–2拍。若串行执行且完全不能重叠，两者合计新增8.32–12.48µs，最终按AXI握手调度仿真确认。网络协议字节不变；握手等待和背压不能在ARVALID成立时改变地址。

### H6：距离表RAM失败【已证实】

**文件／模块／位置：** `eth/acx750_m3tl_targets.sv`134/167/209/255。

`d2_mem[32]×32=1,024bit`，未显式清零，但写在异步reset敏感过程；日志685–686说明溶成FF。拆成纯posedge写、保留小LUTRAM即可；sqrt准备状态若同步读新增1拍/目标，32目标最多320ns。sqrt已串行，不是32个并行平方根器。

## 4. Medium / Low 问题

| 等级 | 文件／位置 | 实际结构与建议 |
|---|---|---|
| Medium | `ar_video.sv`17–39、102–125、167–179 | compact的prefix1637+holding1657+active1657=4,951bit，对应overlay约5,020FF。DCPreq/holding控制扇出1,637/1,624，当前正裕量。可减少控制端副本或流式加载；像素端仍需并行参数，CDC稳定保持与帧边界交换不可删 |
| Medium | `ar_video.sv`132–164 | 32组像素边界比较及红/青/普通OR汇总，overlay约6,096LUT。不是自动32级优先链；若实测路径落在这里，在边界/命中结果与合成之间插1像素流水级，sideband与背压同时延迟，稳态一像素/拍 |
| Medium | `fixed_projector.sv`54–92 | 九个旋转乘积和插值产品已分阶段；52DSP不是器件DSP耗尽。先解决LUT地址/MUX，不盲目共享所有乘法器或继续加运算流水线 |
| Low | `acx750_chassis_rx.sv`135/144/184/191 | 60×8帧存储只480bit，整模块606FF；有常量地址和变量地址两个写分支，可合并成单写LUTRAM，但相对主热点小 |
| Low | `eth_rx/ip_checksum.v`49–56、`eth_tx/ip_checksum.v`58–65 | 9项16bit求和→32bit寄存器→carry折返；没有当前最差路径证据，仅保留观察，不为了源码长修改 |
| Low/正常 | `acx750_hud.sv`135/141、字体case | 35bit字形只取一个动态bit，约35:1单bit选择；不能当完整35bit输出barrel shifter；实际HUD128LUT/24FF |
| 正常 | UART/MDIO/I2C localparam、DDR clogb2、TOP帧地址 | 参数除法、循环、常量乘法是编译期运算；不产生软件式运行时除法器 |
| 正常 | RGMII generate4、write_bridge generate3、TOP lat_x/y | 小规模明确并行通道/短流水线；不因出现for/generate就误报 |

没有发现上述主要存储/选择网络以外、可由当前证据直接升级为Critical/High的新热点。

## 5. Memory / BRAM 推断检查

容量为名义RTL容量，可能被裁剪/补齐。sync表示读值在时钟边沿输出；异步表达式是否被工具吸收地址寄存器，另外标注实际映射。以下覆盖直接设计源中的存储、常量表、短数组及packed状态；simulation数组不占本轮硬件。

| 文件／数组／位置 | 深度×位宽＝bit | 读／写／复位 | 当前结果与处理 |
|---|---|---|---|
| perception_regs shadow /25 | 64×32=2048 | 字节写；无对外读；整片reset | FF；少量scalar可保留，按真实端口设计 |
| perception_regs cfg /25 | 64×32=2048 | 全量并行读/复制；reset | FF；scalar按消费者分组 |
| perception_regs lut_shadow /25 | 221×32=7072 | 字节写，全量复制读；reset | FF；准备bank及同步读 |
| perception_regs lut /25 | 221×32=7072 | 并行导出/异步MUX；全量copy/reset | FF；必须同时改接口，非加属性即可 |
| perception_regs snapshot /26 | 416×32=13312 | 32/12字同拍写；异步word选择，RDATA注册；reset | FF；记录bank/适配AXI同步响应 |
| targets payload_b /133 | 516×8=4128 | 14/2字并写；全并行导出；无数组reset | FF/译码；128bit记录RAM＋字节读接口 |
| targets d2_mem /134 | 32×32=1024 | 时钟write，asyncreset过程；字选择装载sqrt | 确认FF失败；独立数据写、LUTRAM或同步RAM |
| full_tx frame_buf /238 | 560×8=4480 | 单字/4字CRC写；async读；无reset | FF/选择网络；header/payload拆分 |
| full_tx grid_buf /239 | 413×8=3304 | 单时钟写、async读、无reset | 合法LUTRAM；模块84LUTRAM，非单数组精确归属 |
| base m3tl_tx frame_buf /139 | 512×8=4096 | 同full的CRC多写/async读，无reset | 无BRAM，4,443模块FF；同类优化 |
| cfg_bridge pkt_buf /90 | 128×8=1024 | 字节写，约6路async读；无数组reset，控制过程带asyncreset | 无RAM，FF/MUX；先请求寄存，后按字/端口组织 |
| chassis_rx frame /135 | 60×8=480 | 同步写，async读；无数组reset，控制同步reset | FF/小MUX；可合并单写，低优先 |
| radar_stream mem /51，两实例 | 各512×9=4608 | 双时钟、async读，写过程asyncreset；无数组reset赋值 | 确认FF失败；独立写可合法LUTRAM |
| grid_reader sbyte /55 | 413×8=3304 | 单写async读，写过程asyncreset；无清零 | 确认FF失败；独立数据过程 |
| cell_ram memory /13，grid bank0/1 | 各3300×233=768900 | 双端口sync读写；无reset；6600次顺序初始化 | 各26 RAMB36，正常；两bank共1,537,800bit |
| lidar_grid queue /35 | 3300×12=39600 | 合并单写/sync读，无reset | 1RAMB36+1RAMB18，已修复正常 |
| lidar_grid visited /37 | 3300×1=3300 | async读、互斥单写、顺序清理 | 实际LUTRAM（补齐4K×1）；不是推断失败 |
| lidar_grid objects /37 | 32×384=12288 | 多async读、动态排序写，无reset | FF/宽MUX；单数组精确FF未提取 |
| mid360_points mem /13 | 2048×8=16384 | sync读/写，无数据reset | 1RAMB18，正常 |
| mid360_points header /14 | 36×8=288 | byte写；多字段常量地址读；无数组reset | 少量FF，合理；le16/le32调用索引为常量 |
| packet_tap mem /13 | 2048×8=16384 | RTL输出memory[rd]，rd寄存；单写，无reset | 实际1RAMB18，地址寄存吸收；存在collision/输出流水警告须单列，不是RAM失败 |
| fixed_projector rotation_products /20 | 9×64=576 | 同拍乘积/阶段读取，无数组reset | DSP/流水寄存器，合理 |
| fixed_projector du /27 | 4×16=64 | 索引write/并行read，无reset | 小寄存器，合理 |
| fixed_projector dv /27 | 4×16=64 | 同上 | 小寄存器，合理 |
| fixed_projector hp /28 | 8×34=272 | 并行乘积→求和，无reset | DSP/寄存器，合理；宽度有边界证明 |
| fixed_projector vp /28 | 4×34=136 | 并行乘积→求和，无reset | DSP/寄存器，合理 |
| ar_video prefix /19 | packed1637bit | 并行capture，控制reset | FF，需稳定处理期间状态 |
| ar_video holding /31 | packed1657bit | 处理完成capture，控制reset | FF，CDC稳定邮箱；不能直接删除 |
| ar_video active /31 | packed1657bit | SOF整片更新，像素reset | FF，逐像素并行框参数；流式替换需改加载组织 |
| acx750_hud_ram mem /23 | 256×8=2048 | 双时钟sync读/写，initial常量初始化，无reset | 1RAMB18，两工程正常 |
| ov5640_init_table_rgb rom /39 | 256×24=6144 | sync读，initial常量，无reset | 1RAMB18，两工程正常 |
| acx750_hud_text TPL /56 | 常量109×8=872 | 模板索引读取，不可变 | ROM/常量MUX，不是可写FF大数组 |
| 两TOP lat_x /273与lat_y /274；base190/191附近 | 各8×12=96 | 邻级shift读写、小数组reset | 正常短寄存器延迟链，共192bit；不优先改RAM |
| write_bridge source_data/data /18/22 | 各wire3×16 | 端口接线 | 不是memory，不计存储容量 |

### 厂商IP／XPM单独汇总

- write_bridge三路XPM异步FIFO，各2048×16=32,768bit，合计98,304bit；实际3 RAMB36。FWFT/READ_LATENCY=0是IP接口行为，不等于原始BRAM可async读。
- MIG、DDR读写FIFO、接收FIFO和时钟IP按实例资源/配置处理；不编辑生成的memory/PHY/resetRTL。本轮actual BRAM已由独立RAM报告核对。
- `cell_ram`宽233bit双端口是实际业务数据，不宜简单改成单字串行而破坏逐点端口/吞吐。
- XC7A200T没有URAM，报告Available URAM=0；建议使用BRAM/LUTRAM，不提出URAM迁移。

BRAM不支持任意多地址同拍写和整片运行时reset。FF、LUTRAM也不是天然错误：必须看端口需求、规模和实际路径，不能为了“全部BRAM”破坏性能。

## 6. High Fanout 检查

以下来自physopt DCP `fanout.rpt`，是实际网表负载数，不是按FF数量估算。部分网名经过跨层优化，不能凭名称独占归因某模块。

| 网／类型 | 实际扇出 | 证据判断 |
|---|---:|---|
| u_rst_sys/rst_sync_reg[1]_0 | 36,410 | 36,365 Slice SR＋5IO＋40其他；当前最差slack+3.464ns，需减少不必要data reset，但不宣称此网已时序失败 |
| u_percep_regs/config_pending015_out | 7,080 | 7,078 Slice CE＋2其他；全量配置/LUT复制热点；当前slack+0.911ns |
| project/lut_index[0]、[1] | 各1,792 | 数据/选择负载，相关负slack；Critical LUT读网络 |
| project/lut_index[2] | 864 | 负slack；动态表选择路径 |
| u_disp/DataReq | 1,739 | 当前正裕量；视频时钟使能、相关data必须保持周期一致 |
| overlay/req1、holding派生使能 | 1,637 /1,624 | 当前正裕量；宽发布与帧边界更新；不能只复制驱动而增加非法控制集合 |
| u_rst_pix/sync_reg[1]_0 | 1,867 | 当前正裕量；检查active数据是否可由box_valid屏蔽，安全状态复位仍保留 |
| u_grid/bidx[1]、[2] | 1,010 /614 | sbyte读选择；当前正裕量 |
| cfg_bridge snap_mode/st派生网 | 943、933、931、929等 | 配置地址/大读MUX；多项负slack |
| u_m3tl/idx[2] | 564 | byte选择；当前正裕量 |
| u_m3tl/u_crc/typ派生网 | 541、538等 | 部分负slack；类型选择与payload/CRC输入网络，不自动等同CRC多项式本身过大 |
| snapshot_start派生网 | 686 | 当前正裕量；metadata/对象capture |

布局早期对象选择网fanout1,408是历史placed网，物理优化后可能复制/改名，不与当前top60重复计数。

控制集合：布局3,826，physopt3,861；后者2,356个集合只有8–9负载，寄存器Slice有10,642个未用位置。详细报告中出现percep/targets/m3tl等名称只能说明相关来源，行可能重叠，不能将其相加宣称唯一模块control set数量。

**可取消reset的候选：** 完整写入后才使用的payload、snapshot/LUT的数据内容、受valid屏蔽的datapath中间量。必须保留可观察的默认值、部分更新初始化、非法地址响应及安全状态；没有这些保护，取消reset会改变功能。FSM、valid、FIFO指针、CDC握手和安全控制不能一并删除reset。

## 7. 宽总线检查

| 总线／宽度 | 源→目的 | 判断／建议 |
|---|---|---|
| pr_cfg /2048bit，TOP213 | perception_regs→ar_wrap→engine→标量参数消费者 | 一部分unused字段裁剪；保留真正并行scalar，按消费者局部寄存，不默认全串行 |
| pr_lut /7072bit，TOP214 | perception_regs→ar_wrap→engine动态字选择→projector | Critical，同步地址读口替代 |
| pr_metadata /1024bit，TOP217 | engine→perception_regs；旁接targets | targets实际只读count6bit，其余可裁剪；snapshot同拍写32word仍需明确端口 |
| pr_object_data /384bit，TOP220 | grid动态对象选择→snapshot及targets | 注册record读输出/valid；各消费者同步延迟索引 |
| tgt_payload /4128bit，TOP247 | targets→full_tx动态byte选择 | Critical，删除整片导出，改记录RAM/地址响应与预取 |
| x0/x1各352bit；y0/y1各320bit | projector→ar_video | 像素每拍检查32框，存在并行理由；控制侧可顺序加载，像素侧维持并行cache |
| rotation /288bit | cfg固定字段→projector九乘积 | 每角点需要并行乘积，局部pipeline已存在；不是默认优化目标 |
| prefix1637/holding1657/active1657 | control→CDC稳定快照→pixel | Medium，握手/帧边界语义不可丢；52个32bit加载word约520ns/100MHz是串行准备预算，非新增显示帧延迟 |
| hp /272bit总容量 | projector内部8路34bit产品 | 模块内DSP流水寄存器集合，不当成跨模块超宽广播 |

宽接口必须结合综合裁剪和实际负载判断；generate固定切片本身是连线，但全量并行可见性导致RAM端口无法映射。

## 8. 组合路径检查

| 路径／实际或待证 | 硬件链 | 具体寄存位置和周期影响 |
|---|---|---|
| copy_index→目标payload；placed -0.906 | 索引译码→384bit对象MUX→sat16比较/饱和→payload译码→FF（含S端） | 对象record读输出一拍；sat16结果＋对应index capture一拍。分别实施，各+10ns，II1；最后capture排空后发布 |
| cfg grp/stride→RDATA；physopt最差-0.352，12级；另有14级 | 小地址乘加→pkt_buf字节MUX→地址译码→416/221:1读MUX→RDATA | cfg准备+1拍，RAM读响应另+1–2拍；完全串行时每请求合计+2–3拍，握手/重叠调度以仿真确认 |
| gy→LUT→插值DSP；-0.323，10级，75.286%连线 | clamp/索引乘加→地址广播→221:1 LUTMUX→sample/权重选择→DSP输入 | 注册LUT读地址和sample标签，在取du/dv前消费response；预取四样本II1，不在已有乘积/求和级上盲加拍 |
| tgt byte index→CRC/发送；相关typ网负slack | 516:1byte MUX→type/header MUX→CRC XOR网络→FF | RAM预取数据寄存；CRC仅在byte_valid消费，保持one-byte/clock；先解决字节选择，后看CRC真实路径 |
| ar_video pixel→colour；待关键路径证据 | 坐标加减→32组边界比较→OR汇总→红青/普通/HUD颜色选择 | 若实测超时，在命中结果与最终colour之间+1像素周期；输入RGB/valid/SOF/EOL一起缓存，II1 |
| ground、queue除55、距离平方；已修复 | 原乘加/除法/DSP级联已被阶段寄存或范围缩位替换 | 不列为当前未修问题；保留既有对拍和0.932ms额外串行执行上界记录 |

物理优化后WHS-0.298ns主要来自MIG PHY OSERDES reset相关路径，尚未路由；不是软件代码风格问题。本轮不改厂商PHY，不加假路径。路由setup/hold同时紧张、Explore/tns_cleanup会增添修复搜索，但结构审计优先于策略重跑。

`report_design_analysis -congestion`在physopt DCP未返回level>5窗口，不能据此否定后续Route35-447拥塞。该DCP早于route，route_status有131,203个未布线网属阶段预期值，不是人工停止时剩余unrouted数。工具congestion页还显示Design State:Routed，此标签不足以证明实际已路由；以route_status和checkpoint来源为准。本轮没有完整的人工停止时路由DCP，不能绘出精确拥塞区域热图。

## 9. 优化优先级

只列最值得先改五项，逐项同配置A/B，不同时重构全部链路。

| 顺序／改动 | Route时间预期 | LUT / FF / BRAM | Timing及延迟 |
|---|---|---|---|
| 1 快照记录RAM＋AXI请求/响应寄存 | 大幅减少选择和控制连线的候选；分钟数待实测 | LUT/FF显著下降候选，BRAM增加，端口/宽度决定数量 | 切断当前最差配置/快照MUX链；读+10–20ns，保持对象capture II1 |
| 2 LUT bank RAM＋带标签同步读口 | 减少7,072bit宽连线与1,792负载选择网络 | LUT/FF下降，少量BRAM增加 | 去掉已负裕量LUTMUX；满批次预取预算+2.56µs，像素II不变 |
| 3 目标record RAM＋注册sat16＋字节读接口 | 减少4,128bit接口、写译码和byte MUX | LUT/FF下降，BRAM/LUTRAM增加 | 捕获+10ns、首字预取+8ns，稳定每拍一字节；结果/CRC不变 |
| 4 雷达/配置FIFO、sbyte、d2存储过程分离 | 减少重复字节控制集合与异步读选择网络 | 优先合法LUTRAM，FF下降；选BRAM时增加BRAM | 保留async读方案附加周期0；同步版本必须计首字/valid延迟 |
| 5 header/payload分离发送缓存（两版） | 减少CRC多地址写与逐字节CE，降低装箱压力 | LUT/FF下降，小BRAM增加；header仍FF | 预取稳态II1；CRC若序写额外48ns准备时间，不加帧队列 |

对象表同步记录读列为下一候选，与1/3共用record接口设计；AR副本精简和像素流水线后置，避免在主热点未解决时增加大量FF。control sets/高扇出诊断必须随每项资源报告一起比较，不只看LUT差值。

## 10. 建议修改

以下是**结构模板，不是已替换、已仿真通过的代码**。正式修改前明确端口、初始化、碰撞、协议、索引标签和背压。不得把模板直接覆盖多写模块。

### 10.1 RAM与valid分离

```systemverilog
(* ram_style="block" *) logic [31:0] mem[0:511];
logic [31:0] read_data;
logic read_valid;
always_ff @(posedge clk) begin
  if(write_en) mem[write_addr] <= write_data;
  if(read_en) read_data <= mem[read_addr];
end
always_ff @(posedge clk) begin
  if(rst) read_valid <= 1'b0;
  else read_valid <= read_en;
end
```

数据无reset；valid确保无效内容不外泄。AXI/stream消费者另加保持层，ready为低时不能覆盖尚未消费的数据；有复位后零读要求的每个字/记录必须有初始化标记或先顺序清理。这不是12/32路同拍snapshot写的直接替代。

### 10.2 保持FIFO异步读，只修写进程

```systemverilog
// 指针/full/同步器仍在原有复位控制进程中。
always_ff @(posedge eth_clk) begin
  if(eth_rst_n && wr_en && !full)
    mem[wbin[AW-1:0]] <= {wr_last,d_d};
end
// 控制进程删除原mem写，避免两个writer；原消费者接口先保持。
```

保留`distributed`模板的异步读，不假设block支持这种裸读口。必须复核跨域reset期间读有效屏蔽、单次写入、full/empty和原溢出规则；正式做FIFO压力/CDC测试。

### 10.3 目标捕获在宽选择后寄存，再写记录

```systemverilog
always_ff @(posedge clk) begin
  if(rst) cap_valid_d <= 1'b0;
  else cap_valid_d <= cap_en && snapshot_busy;
  if(cap_en && snapshot_busy) begin
    cap_index_d <= snapshot_index;
    cap_fields_d <= {sat16(o_x0),sat16(o_x1),sat16(o_y0),
                     sat16(o_y1),sat16(o_z0),sat16(o_z1)};
  end
end
// 下一拍使用cap_index_d/cap_fields_d写一个宽record。
// last记录的cap_valid_d排空后才进入sqrt/发布；id/flags字节顺序保持。
```

不要让snapshot_busy的下降沿先于最后延迟写就触发发布；distance字段写要与capture读改写端口互斥或独立存储。已有one-record/cycle输出保持。

### 10.4 配置与LUT请求锁存

```systemverilog
// PREP阶段，尚未对外assert AW/AR/WVALID。
req_addr <= cur_addr;
req_value <= cur_value;
// 下一阶段输出req_*，直到各自握手完成都保持。
// LUT读请求同时寄存sample_tag，下一拍data+valid+tag对应。
```

确认并行AW/W接受、R/B背压、reset丢弃未完成请求和partial config行为。bank切换后必须维护后续增量更新的基准，不把旧active误作完整shadow。

### 10.5 发送缓存与流接口

header/CRC32保留32byte寄存器；payload放单写RAM，网络按header→payload顺序输出。读RAM有一个请求周期，建立预取寄存器，只有`tx_req`或valid/ready接受时才推进当前索引。CRC更新严格跟已接受的字节，最后一个字节接受后才ack；目标RAM在ack之前归发送方所有。

记录下游无ready（GMII发送请求接口）与有ready（内部AXIS接口）的区别，不给不能停的PHY制造无效气泡。改变frame_buf准备状态只能改变已声明的局部周期，不能改协议长度、顺序、CRC、序号和目标有效年龄。

### 修改后的最低验证清单与以后编码

- 同段整数向量对拍；边界/排序/满32目标/40000点、默认LUT、partial config、非法索引。
- RAM初始化可见性、同地址碰撞、最后一条pipeline排空；AXI独立AW/W、R/B背压；DMA/FIFO reset及溢出。
- payload byte-for-byte、CRC、序号/ack、慢接收和所有包长度；一字节/拍、视频一像素/拍和SOF/EOL一致性。
- 模块RAM/DSP实际推断→整机层级资源/control sets/fanout→布局Slice/拥塞→完整route WNS/WHS/DRC；最后才bit。
- 后续每次写代码先按 [FPGA与嵌入式桌面开发规范](07_开发工具与规范.md#doc-001)确定硬件结构，禁止把C/Python软件循环机械转成RTL大并行网络。规范分别列出FPGA、嵌入式DMA/所有权、桌面UI/队列的开发要求。
- 用户新增的全局 FPGA / AGENTS.md 约束已落实到规范：设计范围包括RTL、约束、工具设置及实现结果；修改前读全层级，模块先验RAM/DSP和CDC/RDC，再按实际问题推进实现。该约束不会把本轮只读审计变成未经验证的RTL修改。

### 证据索引

- 覆盖/审计前输入哈希：`results/route_audit_20261001/coverage.json`。
- 最终核验：同目录`verification.json`，550份输入哈希全部匹配、九项报告OK、十节标题及文档编码/本地链接检查通过，核验退出0。诊断工具没有综合/布局/布线/写设计命令。
- 分项原始审计：同目录`telemetry.txt`、`memory.txt`。
- DCP独立报告：同目录`full_physopt/{utilization,hierarchy,control_sets,fanout,setup,hold,ram,congestion,route_status}.rpt`，`ff_owners.tsv`及`report_status.tsv`（9项OK）。
- 工具：`tools/scripts/audit_route_checkpoint.tcl`，只能open_checkpoint/report/close，不做实现；通过既有监视器执行，退出0。日志`vivado_project/logs/route_structure_audit_console.log`。
- 原实现证据：full `.runs/impl_1/runme.log`、`monitor_place_critical_paths.rpt`、`acx750_full_top_control_sets_placed.rpt`；综合`runme.log`和资源报告。
- [AMD UG949控制集合](https://docs.amd.com/r/2021.2-English/ug949-vivado-design-methodology/Reduce-the-Number-of-Unique-Control-Sets)、[拥塞方法](https://docs.amd.com/r/2021.2-English/ug949-vivado-design-methodology/Addressing-Congestion)、[2020.2高扇出报告](https://docs.amd.com/r/2020.2-English/ug835-vivado-tcl-commands/report_high_fanout_nets)。官方资料用于设计方法，本机DCP报告用于当前结论。

**完成边界：** 本轮完成结构审计和防复发规范，没有应用建议，没有优化后的资源/耗时/时序结果，也没有full合格bit或新的上板验证。

---

<a id="doc-009"></a>

## 来源：vivado_project/source_snapshot/fpga_acx750/scripts/README.md

相同正文的原位置：`旧项目/2026-10-01_目录整理/fpga_acx750/scripts/README.md`。

# ACX750 工程构建脚本说明

面向 **ACX750（XC7A200T-FBG484-2，纯 FPGA 无 PS）**，工具链 **Vivado 2018.3**
（`ip/` 下的厂商 IP 由 2018.3 生成，**不要用 2020.2**）。

所有脚本路径都从脚本自身位置反推（`<工程>/scripts/`），不依赖机器绝对路径。

## 目录约定

```
fpga_acx750/
  rtl/         自研 RTL（顶层 acx750_top.sv，全局常量 acx750_defs.svh）
  rtl/vendor_ref/ 厂商原文（display/ddr3/eth_rx/eth_tx/eth_mdio/camera）
  ip/          厂商 IP（*.xci，脚本加入时排除 pll.xci）
  constraints/ *.xdc
  build/        脚本产物（工程、报告、日志、脚本生成的 IP）
  output/       bit / bin / xsa
```

## 脚本一览

| 脚本 | 作用 |
|------|------|
| `build_project.tcl` | 建工程 + 递归收源 + 加 IP + 现场生成 `clk_sys_wiz` + 加约束 + 源码快照 + 综合 |
| `build_image.tcl`    | 综合 → 实现 → 布线 → 时序/DRC 门限 → 出 bit / xsa |
| `jtag_program.tcl`   | JTAG 下载 bit（掉电丢失） |
| `program_flash.tcl`  | bit 转 bin 并烧写 QSPI Flash（MX25L12835F 16MB，掉电保留） |
| `run_vivado.ps1`     | 统一 PowerShell 包装，日志 tee 到 `build/` 并按判定期标记决定退出码 |

## 推荐用法（PowerShell）

```powershell
cd mid360_pc_fpga\fpga_acx750

# 只建工程 / 收源 / 生成 IP（rtl 还在写时用来自检）
.\scripts\run_vivado.ps1 -Step project -NoSynth

# 建工程并综合自检
.\scripts\run_vivado.ps1 -Step project -Jobs 8

# 完整实现并出 bit
.\scripts\run_vivado.ps1 -Step image -Jobs 8

# 复用已完成的综合，只重跑实现（反复调时序时用）
.\scripts\run_vivado.ps1 -Step image -RouteOnly

# 下载 / 烧 Flash
.\scripts\run_vivado.ps1 -Step jtag
.\scripts\run_vivado.ps1 -Step flash
```

等价的直接调用（不经 PowerShell）：

```
C:\Xilinx\Vivado\2018.3\bin\vivado.bat -mode batch -source scripts\build_image.tcl -tclargs -jobs 8
```

> `-mode batch` 表示非交互运行；脚本内部用判定期标记（见下）判成败，**不靠退出码**。
> `run_vivado.ps1` 会再依据标记翻译成退出码：`0` 通过 / `2` 门限未过 / `1` 脚本异常。

## 判定标记怎么读

运行后会在 `build/<step>.log` 里看到这些标记：

| 标记 | 含义 |
|------|------|
| `IP_PORTS_OK=YES` | `clk_sys_wiz` 实际端口与顶层例化一致（`clk_in1 resetn clk_out1..4 locked`） |
| `SYNTH_STATUS=...` | 综合状态，含 `Complete` 才算通过 |
| `RESOURCE_GATE ...` | 综合后资源占用（LUT/FF/BRAM/DSP），硬门限见下 |
| `EMPTY_PORT_MATCH=...` | xdc 里 `get_ports` **匹配为空**的端口；正常应为 `None` |
| `SNAPSHOT_STATUS=ok` | 源码在构建期间未被改动（有改动会变成 `CHANGED:...`） |
| `ROUTE_STATUS=...` | 布线运行状态 |
| `ROUTED_WNS=.. ROUTED_WHS=.. DRC_BAD=..` | 布线后建立/保持余量与 DRC 严重错误数 |
| `GATE_FAIL: ...` | 具体哪一项没过，并打印最差路径（时钟、起止点、slack） |
| `BIT_RUN_STATUS=...` | `write_bitstream` 运行状态 |
| `BIT_READY=<path>` | 出 bit 成功，路径为 `output/acx750_top.bit` |
| `BIT_SKIPPED=<原因>` | 门限没过，主动跳过出 bit |
| `JTAG_STATUS=OK` / `FLASH_STATUS=OK` | 下载 / 烧写成功 |

### 资源门限（XC7A200T）

```
LUT  <= 134600
FF   <= 269200
BRAM <= 730        （折算：2*BRAM36 + BRAM18）
DSP  <= 740
```

### 时序 / DRC 门限

`ROUTED_WNS >= 0` 且 `ROUTED_WHS >= 0` 且 `DRC_BAD == 0`，任一不满足则 `BIT_SKIPPED`。

## 失败时先看哪个文件

1. `build/source_snapshot.txt` —— 触发 `SNAPSHOT_STATUS=CHANGED` 时，对照它确认哪个源文件被改。
2. `build/synth.log` 或 `build/image.log` 末尾 —— 综合/实现的 `runme.log` 会被原样回显。
3. `build/routed_timing.rpt` / `build/routed_drc.rpt` / `build/routed_utilization.rpt` —— 时序、DRC、资源详情。
4. `build/synthesis_timing.rpt` / `build/synthesis_hierarchy.rpt` —— 综合阶段的时序与层次资源。
5. `EMPTY_PORT_MATCH` 非 `None` —— 说明某条 xdc 约束的目标端口在 RTL 顶层不存在，上板前必须处理（脚本故意不 `-no_assert` 掩盖）。

## 注意事项

- `ip/pll.xci` **不使用**，加入工程时被显式排除；时钟改用脚本现场生成的 `clk_sys_wiz`
  （输入 50 MHz 单端，输出 200/100/33/24 MHz，低有效复位口 `resetn`，带 `locked`）。
- 顶层固定为 `acx750_top`；综合策略 `Vivado Synthesis Defaults`，
  实现策略 `Performance_ExplorePostRoutePhysOpt`。
- 脚本会跳过目录名含 `tb`/`tests`/`sim` 的子树，以及文件名以 `_tb.v`/`_tb.sv` 结尾的文件。
- `.svh` 只作 include 路径（`rtl/` 与 `rtl/vendor_ref/display/` 均会加入），不作为源文件。
- **厂商 IP 的加入方式**：Vivado 2018.3 里若多个 `.xci` 放在同一目录，会被判为
  `Shared output directory` 而 **locked**，其 OOC 综合会报 `module ... not found`。
  因此 `build_project.tcl` 会把 `ip/*.xci` 复制到 `build/vendor_ip/<ip>/` 各自独立目录
  后再加入（**不改动 `ip/` 原文件**），并为它们生成输出产物。日志里可看 `IP_GEN_OK=<ip>`。
- **MIG 的 `mig_a.prj`/`mig_b.prj`**：MIG 的配置存在这两个随附 `.prj` 里，而 `ip/` 目前
  只有 `.xci`。脚本会 best-effort 到仓库上一级（FPGA 根）下 ch57 **32bit** 例程目录
  自动补齐（日志 `MIG_VENDOR_DIR=` / `MIG_AUX_COPY=`）；若找不到会打印
  `MIG_AUX_MISSING`，此时需手工把 `mig_a.prj`、`mig_b.prj` 放进 `ip/`。
  **务必用 32bit 例程的 prj**（16bit 的 MIG 参数不同，不可用）。

---

<a id="doc-010"></a>

## 来源：vivado_project/source_snapshot/fpga_acx750/sim/README.md

相同正文的原位置：`旧项目/2026-10-01_目录整理/fpga_acx750/sim/README.md`。

# ACX750 RTL 仿真自检

本目录（`fpga_acx750/sim/`）放纯仿真用的 SystemVerilog 测试台，配合
`fpga_acx750/tests/run_rtl_tests.py` 用 Vivado 自带仿真器跑 RTL 自检。
测试台全部**自检**：结束时打印明确的 `PASS ...` 或 `FAIL ...`，不需要人工看波形。

## 怎么跑

环境：Vivado **2018.3**（默认工具目录 `C:\Xilinx\Vivado\2018.3\bin`），
Python 3（用 `py -3` 即可，只用标准库）。

```powershell
# 在仓库根 fpga_acx750 目录下
py -3 tests\run_rtl_tests.py

# 只跑个别用例
py -3 tests\run_rtl_tests.py --only tb_cmd tb_reset

# 指定其它 Vivado 版本
py -3 tests\run_rtl_tests.py --tools C:\Xilinx\Vivado\2020.2\bin
```

驱动对每个用例依次执行：

```
xvlog -sv -i rtl <tb.sv> <依赖的 rtl...>      # 分析
xelab -debug typical <tb_top> -s sim_snap     # 展开（--debug 保证 $display 输出）
xsim  sim_snap -runall                        # 仿真
```

**判定标准**：三步都没有 `FATAL_ERROR`/非零返回码，且 xsim 输出里出现 `PASS`
且不出现 `FAIL`，即判该用例通过。最后汇总打印 `通过 N 项，失败 M 项`，
并用退出码反映结果（全过为 0）。编译日志与快照写在 `tests/output/<用例名>/`。

## 各测试台

| 测试台 | 验证内容 | 依赖的 RTL |
|---|---|---|
| `tb_uart_loopback.sv` | `tx.txd` 直接接 `rx.rxd` 回环，发 11 个字节（含 `0x00/0xFF/0x55/0xAA` 边界），校验收发完全一致；`CLK_HZ=1 MHz / BAUD=100 kHz` 加快仿真 | `rtl/common/acx750_uart_tx.sv`、`rtl/common/acx750_uart_rx.sv` |
| `tb_cmd.sv` | 注入 `rx_valid/rx_data`：复位默认阶段、`'0'..'7'` 逐个切阶段、非法字符忽略、`'c'/'C'` 各产生 1 个且宽度恰为 1 拍的 `clear_stats` 脉冲 | `rtl/common/acx750_cmd.sv` |
| `tb_self_pattern.sv` | `x<400` 棋盘（`x[4]^y[4]`）、`400..599` 绿色行号（`{5'h00,y[5:0],5'h00}`，即 RGB565 绿段 bit10:5）、`x>=600` 红蓝斜率（`{x[4:0],6'h00,y[4:0]}`）三区间的已知点；并校验同一 `(x,y)` 在不同"帧"重复求值结果恒定 | `rtl/ddr3/acx750_self_pattern.sv` |
| `tb_hud_text.sv` | 把 `wr_en/wr_addr/wr_data` 写进 256x8 数组，刷满一轮（恰好 256 次写）后逐字节比对 8 行 x 32 列：`ACX750 BRINGUP` / `STG3 P1 D1 C0 E1` / `FRM xxxxxxxx` / `RXP/DRP/CAM/PTS` / `MID360 AR`，其余位置必须为空格 `0x20`（hex 为大写） | `rtl/display/acx750_hud_text.sv` |
| `tb_reset.sv` | `locked=0` 或按键按下时 `rst_n` 保持 0；释放后需 `>= DEBOUNCE_CLK` 才拉高；按键再次按下立即拉低；再次释放重新去抖拉高 | `rtl/common/acx750_reset.sv` |
| `tb_uart_report.sv` | 把 `txd` 用 `acx750_uart_rx` 收回来，校验一行 34 字节、以 `'S'` 开头、以 CR/LF 结尾，`F`/`X` 后的 8 位 hex 与 `frame_cnt`/`drop_cnt` 一致 | `rtl/common/acx750_uart_report.sv`、`rtl/common/acx750_uart_tx.sv`、`rtl/common/acx750_uart_rx.sv` |

## 说明与注意

- 编译时统一加了 `-i rtl`，因此 RTL 里 `` `include "acx750_defs.svh" `` 之类都能解析。
- 只用 Vivado 2018.3 支持的 SystemVerilog 子集，未使用断言/随机约束等特性。
- 测试台依赖 RTL 的对外行为，**不修改任何 `rtl/` 文件**；若被测 RTL 有缺陷，
  测试台会如实在末尾打印 `FAIL` 并列出失配的字节/列，由 RTL 维护者修正。

---

<a id="doc-011"></a>

## 来源：vivado_project/source_snapshot/fpga_acx750_full/scripts/README.md

相同正文的原位置：`旧项目/2026-10-01_目录整理/fpga_acx750_full/scripts/README.md`。

# ACX750 工程构建脚本说明

面向 **ACX750（XC7A200T-FBG484-2，纯 FPGA 无 PS）**，工具链 **Vivado 2018.3**
（`ip/` 下的厂商 IP 由 2018.3 生成，**不要用 2020.2**）。

所有脚本路径都从脚本自身位置反推（`<工程>/scripts/`），不依赖机器绝对路径。

## 目录约定

```
fpga_acx750_full/
  rtl/         自研 RTL（顶层 acx750_full_top.sv，全局常量 acx750_defs.svh；
               含 perception/、video/ 等子目录——脚本递归收集）
  rtl/vendor_ref/ 厂商原文（display/ddr3/eth_rx/eth_tx/eth_mdio/camera）
  ip/          厂商 IP（*.xci，脚本加入时排除 pll.xci）
  constraints/ *.xdc（与 fpga_acx750/ 基线共用，管脚相同）
  build/        脚本产物（工程在 build/acx750_full/、报告、日志、脚本生成的 IP）
  output/       bit / bin / xsa（默认命名 acx750_full_top.*）
```

## 脚本一览

| 脚本 | 作用 |
|------|------|
| `build_project.tcl` | 建工程 + 递归收源 + 加 IP + 现场生成 `clk_sys_wiz` + 加约束 + 源码快照 + 综合 |
| `build_image.tcl`    | 综合 → 实现 → 布线 → 时序/DRC 门限 → 出 bit / xsa |
| `jtag_program.tcl`   | JTAG 下载 bit（掉电丢失） |
| `program_flash.tcl`  | bit 转 bin 并烧写 QSPI Flash（MX25L12835F 16MB，掉电保留） |
| `run_vivado.ps1`     | 统一 PowerShell 包装，日志 tee 到 `build/` 并按判定期标记决定退出码 |

## 推荐用法（PowerShell）

```powershell
cd mid360_pc_fpga\fpga_acx750_full

# 只建工程 / 收源 / 生成 IP（rtl 还在写时用来自检）
.\scripts\run_vivado.ps1 -Step project -NoSynth

# 建工程并综合自检
.\scripts\run_vivado.ps1 -Step project -Jobs 8

# 完整实现并出 bit
.\scripts\run_vivado.ps1 -Step image -Jobs 8

# 复用已完成的综合，只重跑实现（反复调时序时用）
.\scripts\run_vivado.ps1 -Step image -RouteOnly

# 下载 / 烧 Flash
.\scripts\run_vivado.ps1 -Step jtag
.\scripts\run_vivado.ps1 -Step flash
```

等价的直接调用（不经 PowerShell）：

```
C:\Xilinx\Vivado\2018.3\bin\vivado.bat -mode batch -source scripts\build_image.tcl -tclargs -jobs 10
```

> `-mode batch` 表示非交互运行；脚本内部用判定期标记（见下）判成败，**不靠退出码**。
> `run_vivado.ps1` 会再依据标记翻译成退出码：`0` 通过 / `2` 门限未过 / `1` 脚本异常。

## 判定标记怎么读

运行后会在 `build/<step>.log` 里看到这些标记：

| 标记 | 含义 |
|------|------|
| `IP_PORTS_OK=YES` | `clk_sys_wiz` 实际端口与顶层例化一致（`clk_in1 resetn clk_out1..4 locked`） |
| `SYNTH_STATUS=...` | 综合状态，含 `Complete` 才算通过 |
| `RESOURCE_GATE ...` | 综合后资源占用（LUT/FF/BRAM/DSP），硬门限见下 |
| `EMPTY_PORT_MATCH=...` | xdc 里 `get_ports` **匹配为空**的端口；正常应为 `None` |
| `SNAPSHOT_STATUS=ok` | 源码在构建期间未被改动（有改动会变成 `CHANGED:...`） |
| `ROUTE_STATUS=...` | 布线运行状态 |
| `ROUTED_WNS=.. ROUTED_WHS=.. DRC_BAD=..` | 布线后建立/保持余量与 DRC 严重错误数 |
| `GATE_FAIL: ...` | 具体哪一项没过，并打印最差路径（时钟、起止点、slack） |
| `BIT_RUN_STATUS=...` | `write_bitstream` 运行状态 |
| `BIT_READY=<path>` | 出 bit 成功，路径为 `output/acx750_full_top.bit` |
| `BIT_SKIPPED=<原因>` | 门限没过，主动跳过出 bit |
| `JTAG_STATUS=OK` / `FLASH_STATUS=OK` | 下载 / 烧写成功 |

### 资源门限（XC7A200T）

```
LUT  <= 134600
FF   <= 269200
BRAM <= 730        （折算：2*BRAM36 + BRAM18）
DSP  <= 740
```

### 时序 / DRC 门限

`ROUTED_WNS >= 0` 且 `ROUTED_WHS >= 0` 且 `DRC_BAD == 0`，任一不满足则 `BIT_SKIPPED`。

## 失败时先看哪个文件

1. `build/source_snapshot.txt` —— 触发 `SNAPSHOT_STATUS=CHANGED` 时，对照它确认哪个源文件被改。
2. `build/synth.log` 或 `build/image.log` 末尾 —— 综合/实现的 `runme.log` 会被原样回显。
3. `build/routed_timing.rpt` / `build/routed_drc.rpt` / `build/routed_utilization.rpt` —— 时序、DRC、资源详情。
4. `build/synthesis_timing.rpt` / `build/synthesis_hierarchy.rpt` —— 综合阶段的时序与层次资源。
5. `EMPTY_PORT_MATCH` 非 `None` —— 说明某条 xdc 约束的目标端口在 RTL 顶层不存在，上板前必须处理（脚本故意不 `-no_assert` 掩盖）。

## 注意事项

- `ip/pll.xci` **不使用**，加入工程时被显式排除；时钟改用脚本现场生成的 `clk_sys_wiz`
  （输入 50 MHz 单端，输出 200/100/33/24 MHz，低有效复位口 `resetn`，带 `locked`）。
- 顶层为 `acx750_full_top`、工程名为 `acx750_full`（**集中在每个脚本顶部的 `$TOP`
  变量 / `run_vivado.ps1` 的 `-Top`**，换顶层只改这一处；也可用命令行覆盖：
  tcl 加 `-top <name>`，PowerShell 用 `-Top <name>`）。综合策略 `Vivado Synthesis Defaults`，
  实现策略 `Performance_ExplorePostRoutePhysOpt`。
- 脚本**递归**收集 `rtl/**/*.sv`、`*.v`，因此 `rtl/perception/`、`rtl/video/` 等新增
  子目录会被自动收入；会跳过目录名含 `tb`/`tests`/`sim` 的子树，以及文件名以
  `_tb.v`/`_tb.sv` 结尾的文件。
- `.svh` 只作 include 路径（`rtl/` 与 `rtl/vendor_ref/display/` 均会加入），不作为源文件。
- **厂商 IP 的加入方式**：Vivado 2018.3 里若多个 `.xci` 放在同一目录，会被判为
  `Shared output directory` 而 **locked**，其 OOC 综合会报 `module ... not found`。
  因此 `build_project.tcl` 会把 `ip/*.xci` 复制到 `build/vendor_ip/<ip>/` 各自独立目录
  后再加入（**不改动 `ip/` 原文件**），并为它们生成输出产物。日志里可看 `IP_GEN_OK=<ip>`。
- **MIG 的 `mig_a.prj`/`mig_b.prj`**：MIG 的配置存在这两个随附 `.prj` 里，而 `ip/` 目前
  只有 `.xci`。脚本会 best-effort 到仓库上一级（FPGA 根）下 ch57 **32bit** 例程目录
  自动补齐（日志 `MIG_VENDOR_DIR=` / `MIG_AUX_COPY=`）；若找不到会打印
  `MIG_AUX_MISSING`，此时需手工把 `mig_a.prj`、`mig_b.prj` 放进 `ip/`。
  **务必用 32bit 例程的 prj**（16bit 的 MIG 参数不同，不可用）。

---

<a id="doc-012"></a>

## 来源：vivado_project/source_snapshot/fpga_acx750_full/sim/README.md

相同正文的原位置：`旧项目/2026-10-01_目录整理/fpga_acx750_full/sim/README.md`。

# ACX750 RTL 仿真自检

本目录（`fpga_acx750/sim/`）放纯仿真用的 SystemVerilog 测试台，配合
`fpga_acx750/tests/run_rtl_tests.py` 用 Vivado 自带仿真器跑 RTL 自检。
测试台全部**自检**：结束时打印明确的 `PASS ...` 或 `FAIL ...`，不需要人工看波形。

## 怎么跑

环境：Vivado **2018.3**（默认工具目录 `C:\Xilinx\Vivado\2018.3\bin`），
Python 3（用 `py -3` 即可，只用标准库）。

```powershell
# 在仓库根 fpga_acx750 目录下
py -3 tests\run_rtl_tests.py

# 只跑个别用例
py -3 tests\run_rtl_tests.py --only tb_cmd tb_reset

# 指定其它 Vivado 版本
py -3 tests\run_rtl_tests.py --tools C:\Xilinx\Vivado\2020.2\bin
```

驱动对每个用例依次执行：

```
xvlog -sv -i rtl <tb.sv> <依赖的 rtl...>      # 分析
xelab -debug typical <tb_top> -s sim_snap     # 展开（--debug 保证 $display 输出）
xsim  sim_snap -runall                        # 仿真
```

**判定标准**：三步都没有 `FATAL_ERROR`/非零返回码，且 xsim 输出里出现 `PASS`
且不出现 `FAIL`，即判该用例通过。最后汇总打印 `通过 N 项，失败 M 项`，
并用退出码反映结果（全过为 0）。编译日志与快照写在 `tests/output/<用例名>/`。

## 各测试台

| 测试台 | 验证内容 | 依赖的 RTL |
|---|---|---|
| `tb_uart_loopback.sv` | `tx.txd` 直接接 `rx.rxd` 回环，发 11 个字节（含 `0x00/0xFF/0x55/0xAA` 边界），校验收发完全一致；`CLK_HZ=1 MHz / BAUD=100 kHz` 加快仿真 | `rtl/common/acx750_uart_tx.sv`、`rtl/common/acx750_uart_rx.sv` |
| `tb_cmd.sv` | 注入 `rx_valid/rx_data`：复位默认阶段、`'0'..'7'` 逐个切阶段、非法字符忽略、`'c'/'C'` 各产生 1 个且宽度恰为 1 拍的 `clear_stats` 脉冲 | `rtl/common/acx750_cmd.sv` |
| `tb_self_pattern.sv` | `x<400` 棋盘（`x[4]^y[4]`）、`400..599` 绿色行号（`{5'h00,y[5:0],5'h00}`，即 RGB565 绿段 bit10:5）、`x>=600` 红蓝斜率（`{x[4:0],6'h00,y[4:0]}`）三区间的已知点；并校验同一 `(x,y)` 在不同"帧"重复求值结果恒定 | `rtl/ddr3/acx750_self_pattern.sv` |
| `tb_hud_text.sv` | 把 `wr_en/wr_addr/wr_data` 写进 256x8 数组，刷满一轮（恰好 256 次写）后逐字节比对 8 行 x 32 列：`ACX750 BRINGUP` / `STG3 P1 D1 C0 E1` / `FRM xxxxxxxx` / `RXP/DRP/CAM/PTS` / `MID360 AR`，其余位置必须为空格 `0x20`（hex 为大写） | `rtl/display/acx750_hud_text.sv` |
| `tb_reset.sv` | `locked=0` 或按键按下时 `rst_n` 保持 0；释放后需 `>= DEBOUNCE_CLK` 才拉高；按键再次按下立即拉低；再次释放重新去抖拉高 | `rtl/common/acx750_reset.sv` |
| `tb_uart_report.sv` | 把 `txd` 用 `acx750_uart_rx` 收回来，校验一行 34 字节、以 `'S'` 开头、以 CR/LF 结尾，`F`/`X` 后的 8 位 hex 与 `frame_cnt`/`drop_cnt` 一致 | `rtl/common/acx750_uart_report.sv`、`rtl/common/acx750_uart_tx.sv`、`rtl/common/acx750_uart_rx.sv` |

## 说明与注意

- 编译时统一加了 `-i rtl`，因此 RTL 里 `` `include "acx750_defs.svh" `` 之类都能解析。
- 只用 Vivado 2018.3 支持的 SystemVerilog 子集，未使用断言/随机约束等特性。
- 测试台依赖 RTL 的对外行为，**不修改任何 `rtl/` 文件**；若被测 RTL 有缺陷，
  测试台会如实在末尾打印 `FAIL` 并列出失配的字节/列，由 RTL 维护者修正。

---

## 感知核 RTL 测试（`sim/perception/`）

本节的测试台来自 7020（XC7Z020）工程的
`fpga_ac880/sensor_perception_ar/tests/`，**原样搬入** ACX750 新工程并做了
行为零改动（每个文件头注明来源，正文与被测逻辑完全一致；`tb_engine.sv`
在 7020 侧本就没有超时块，搬入时保持一致）。搬移时只调整了文件位置，
测试台本身不含文件路径；`` `include "perception_types.svh" `` 由驱动通过
`-i rtl/perception` 解析。

被测 RTL 位于 `fpga_acx750_full/rtl/perception/`，由感知核搬运任务并行
产出；本目录的测试台**不修改**这些 RTL。

### 怎么跑

统一由 `fpga_acx750_full/tests/run_perception_tests.py` 驱动（Python 3 标准库，
调用 Vivado 的 `xvlog`/`xelab`/`xsim`）：

```powershell
# 在仓库根 fpga_acx750_full 目录下，跑平台 + 感知核全部用例
py -3 tests\run_perception_tests.py

# 只跑感知核那一组
py -3 tests\run_perception_tests.py --skip-platform

# 只跑个别用例（平台/感知核通用）
py -3 tests\run_perception_tests.py --only tb_math tb_ar tb_engine

# 指定其它 Vivado 版本
py -3 tests\run_perception_tests.py --tools C:\Xilinx\Vivado\2020.2\bin
```

驱动对每个用例依次执行
`xvlog -sv -i rtl -i rtl/perception <tb.sv> <依赖 rtl...>` →
`xelab -debug typical <tb> -s sim_snap` → `xsim sim_snap -runall`，
判定标准与平台组一致（无 `FATAL_ERROR`/非零返回码，且输出出现 `PASS`
不出现 `FAIL`）。最后汇总打印 `通过 N 项，失败 M 项，跳过 S 项`。
中间产物写在 `tests/output/<用例名>/`（已被 `.gitignore` 的 `output/`
规则覆盖，不会污染工程根目录）。

**跳过语义**：若 `rtl/perception/` 下缺少某用例依赖的 RTL（例如感知核
还没搬完），驱动会打印 `[SKIP] 用例名跳过：rtl/perception/ 缺少 xxx`
并计入“跳过”而不是“失败”。等 RTL 就位后重跑即可。

### 各测试台

| 测试台 | 验证内容 | 依赖的 RTL（`rtl/perception/`） |
|---|---|---|
| `tb_math.sv` | `unsigned_div64`/`integer_sqrt64` 的除法与开方，含 `0`、`1`、`64'hffffffffffffffff` 等边界 | `integer_math.sv` |
| `tb_motion.sv` | `chassis_motion` 的速度滤波、里程积分、dt 超时拒绝、极值有符号速度、最大 dt、余数保留 | `integer_math.sv`、`chassis_motion.sv` |
| `tb_projector.sv` | `fixed_projector` 的投影坐标、标定门控、立体视差、Q8 LUT 有符号修正与向下取整 | `integer_math.sv`、`fixed_projector.sv` |
| `tb_ar.sv` | `ar_video`（`COMPACT_HUD=0`）的 AR 边框像素、随机背压、SOF 帧更新、立体、过期框、里程/速度 BCD 转换 | `ar_video.sv` |
| `tb_ar_compact.sv` | 同 `tb_ar`，但 `ar_video` 参数为 `COMPACT_HUD=1`，校验紧凑 HUD 下的 BCD 布局 | `ar_video.sv` |
| `tb_hud.sv` | `ar_video`（`test_mode=1`）紧凑 HUD 的逐像素位图、控制/视频双时钟、随机背压，且不显示速度/里程文字 | `ar_video.sv` |
| `tb_parser.sv` | `mid360_points` 的报文 CRC 校验、点计数、零 CRC 固件兼容、有符号笛卡尔点解析（输入报文由驱动用标准库生成） | `integer_math.sv`、`mid360_points.sv` |
| `tb_regs.sv` | `perception_regs` 的读写、AW/W 独立握手、延迟提交、一致快照（AXI 端口由 tb 直接驱动，**不依赖任何 Xilinx AXI IP**） | `perception_regs.sv` |
| `tb_engine.sv` | `perception_engine` 在无雷达输入时的合成叠加心跳与快照有效标志 | `integer_math.sv`、`packet_tap.sv`、`mid360_points.sv`、`cell_ram.sv`、`lidar_grid.sv`、`chassis_motion.sv`、`fixed_projector.sv`、`ar_video.sv`、`perception_engine.sv` |
| `tb_grid.sv` | `lidar_grid` 网格聚类**编译 + 仿真冒烟**（驱动注入确定性点云、读回 `grid_output.txt`） | `cell_ram.sv`、`lidar_grid.sv` |

### 已知差异与注意

- **`tb_grid` 的数值比对未搬**：7020 侧由 `run_rtl_tests.py` 的 `verify_grid`
  用 numpy 参考模型逐对象比对（含边界/溢出/随机/真实录制等 8 个子 case，
  即“18 项验收”里的 8 条）。本工程驱动只用标准库，**不复现该数值比对**，
  只做编译 + 仿真冒烟；`tb_grid` 自身只 `$display("PASS grid")`。若要完整
  验证网格聚类数值，请仍以 7020 驱动的 `verify_grid` 为准。
- **无 PS/AXI IP 依赖**：`tb_regs`/`tb_engine` 里的 `axi`/`s_axi_*` 只是被测
  模块的普通端口，由测试台直接驱动，因此无需 Zynq PS 或 AXI IP，可直接搬移。
- 7020 驱动的“18 项验收”= 本组 9 个独立 tb（math/motion/projector/ar/
  ar_compact/hud/parser/regs/engine）加上 `parser` 的第 2 个 case
  （Cartesian_type2）、以及 `grid` 的 8 个子 case；本驱动把 parser 的两个
  case 合并为一次运行（输入报文即按 Cartesian_type2 的标准库布局构造）。

---

<a id="doc-013"></a>

## 来源：存储结构修复交接_2026-10-01.md

# 存储结构修复与 OV5640 迁移交接

> **最终停工状态：2026-10-01 18:08 左右，5 小时窗口 used=95%、remaining=5%。按用户最新要求停止启动开发和编译。本轮两个整机 preflight 已正常结束，无本轮继续运行的构建；没有启动新布局布线，没有生成新 bit。先读本段和文末最终结果，上文中“正在验证／已启动”均为过程记录。**

## 本轮执行规则

- 最新用户规则：仅以 **5 小时额度窗口剩余 5%** 为停工线，周额度不参与。到线不启动新开发或编译，保存状态、证据和下一步。本规则覆盖历史 50%、20% 和其他停工阈值。
- 只修改 `vivado_project/acx750`、`vivado_project/acx750_full` 活动工程。旧工程、来源快照、厂商原工程和可研保持历史用途。
- HDL/XDC 保持 GBK/CP936、无 BOM；新增 Python/Tcl 使用 ASCII 或 UTF-8 无 BOM，Markdown 使用 UTF-8 无 BOM。中文注释乱码专项尚未处理。
- 所有构建走 `tools/run_build.py` 自动打开监视器。重型综合和实现依次执行，不并发占用多个整机 Vivado。

## 已实际修改的结构

### C1：结果快照

`acx750_full/.../perception/perception_regs.sv` 已应用补丁。

- 对象快照改为 12 个 32×32 同步存储 bank，metadata 的 32 字仍为寄存器。
- 数据 memory 不循环复位；32 个有效标志复位，未初始化记录通过 AXI 返回零。
- 在 AR 接受时锁存字段和有效性，下一拍完成对象读；READ_FIRST 同地址碰撞、AXI 背压和部分更新语义保留。
- 对象 AXI 读增加 1 个 100 MHz 周期，即 10 ns；对象捕获仍为每拍一条、32 拍一批，不增加扫描周期或视频排队。
- 自检已通过：1,681 项检查、2 次同地址碰撞（包括第一次未初始化碰撞）、65 条捕获（包含复位打断的部分批次）。仿真入口退出 0。
- 准备、原始字节备份、哈希、TB、Tcl、结果在 `results/c1_snapshot_20261001`。**综合推断与整机收益待结果确认，不能仅凭 ram_style 声称 BRAM 已推断。**

### 小型存储：3 处写进程

Full 中 `acx750_radar_stream.sv`、`acx750_grid_reader.sv`、`acx750_m3tl_targets.sv` 的存储写入移入不带异步复位的纯时钟进程；控制复位保留，旧写语句删除，无重复写驱动。

- 雷达 FIFO 写入保留复位、写使能和非 full 条件。
- 栅格字节写入保留 S_EMIT 和 emit_byte 条件，异步读口保持原样。
- targets 仅拆分 d2 存储写入，饱和处理和 payload 接口保持原样。
- 不增加周期。前后备份/哈希、差分测试和综合入口在 `results/route_audit_20261001/small_ram_fix`。
- 最初短仿真存在工具启动/源文件问题，正在修复验证入口；失败不等于这些 RTL 已证明有功能错误，也不能写成通过。

### 网络发送缓存：4 个字节 bank

两活动工程的 `acx750_m3tl_tx.sv` / `acx750_m3tl_full_tx.sv` 已修改。

- 原 512/560 字节 packet memory 的 CRC 四字节并行写，改为 4 个 128×8 / 140×8 的单写口 bank。
- 普通字节写只使能一个 lane；CRC 写各 lane 一个字节，字节顺序不变。
- 采用异步读取 LUTRAM 模板，输出仅需 4:1 字节选择；不增加周期、不改变 tx_req 握手、包长度、CRC 或稳态字节吞吐。
- 原始字节和哈希在 `results/tx_banks_20261001`；重复执行补丁脚本会拒绝覆盖备份。
- 初次差分未出现字节/控制差异，但覆盖门限失败：TB 将 tgt_valid 固定为 1，没有按既有协议在 ack 后撤销，导致只有第一包目标被消费。已修正测试驱动，正在重新验证，未因此修改设计协议。

### OV5640 / CAMERA / AR

两 top 的 OV5640 和相机状态尺寸改为 800×480 RGB565；CAMERA 从 DDR 读回图像；AR 的 DDR 写源映射到相机，不再停留在无效 stage。Full 的 projector、engine、AR wrap 显式使用 800×480、X 偏移 0；独立 projector 默认保留旧 640×480/+80 供兼容测试。

- 没有新增视频流水级或整帧等待；每周期一像素的接口保持。
- 已有 AR wrap 回归 EXIT 0 / PASS，视频延迟 L=1，数据和 SOF/EOL 差异均为 0。
- 正在补 800/+0 和旧 640/+80 几何对拍、两顶层写源/层次验证。初次启动有 Broken pipe / source 添加失败，须修验证环境后再判断 RTL。
- 800×480 相较 640×480 每帧像素增加 25%；真实 PCLK、帧率和 FIFO 裕量仍需上板。

## 未完成的关键结构

1. C2：7,072 位畸变表输出和动态选择仍在；尚未改成同步 RAM 读接口。配置 active/shadow、部分更新、提交边界及读一致性必须保留。
2. C3：4,128 位 targets payload、动态字节选择和目标遥测跨时钟发布/ack 仍在；仅 d2 写进程已改，不代表 payload 缓存或 CDC 已修好。
3. CAMERA_STATUS 仍是像素累计数、last_ms=0，需真实 DVP 行/帧校验和安全事件 CDC；不能声称 DDR 完整帧已提交。
4. 最新完整帧三缓冲、DDR 所有权和溢出后帧重同步尚未实现；CAMERA/AR 切换仍走原 stage 清空过程。
5. M3TL type6 只有 12 字节状态，尚无视频像素网络链路。树莓派 5 仍需相机分片接收/完整帧提交接口。
6. OV5640 的 800×480 内外参/畸变参数须重新生成、测量；不得把旧 USB 标定当作有效对齐。
7. Full 没有合格新 bit。历史基线 bit 和旧报告不能作为本次改动的实现或上板证据。

## 下一次直接做什么

1. 收齐正在运行的短仿真结果，修实际失败；不重新开展全工程审计。
2. 模块 before/after OOC 综合，记录 primitive、FF/LUT、控制集合与存储推断。先 C1，再小型 memory，随后 packet bank；重型构建依次执行。
3. C1、packet bank 和小型 memory 必须有协议/碰撞/复位证据才合入整机门限检查；若资源没有减少，检查工具真实推断而不是调整注释或强行压低警告。
4. 继续 C2、C3 根因修复，保持算法精度、快照一致性和协议字节顺序。预计新增的小量控制周期必须单独说明，不增加整帧积压。
5. 运行整机 preflight，比较 Slice packing、control sets、RAM、扇出和最差路径。结构尚未解除前不再花一小时试 route。
6. 整机路由 WNS/WHS≥0，DRC/CDC/引脚门限通过才生成候选 bit；随后单链路和三路真实板测。红青 AR 与多视角数字孪生仍分别验收。

## 已排除与不能使用的结论

- 不能以 LUT 只有约 41% 推断可轻松布线：此前 Slice 约 94.87%、control sets 3,861，实有拥塞日志。
- 不通过错误 false path、随意 multicycle 或降低目标频率掩盖结构问题。
- 不把准备补丁、自检通过、OOC 综合、整机 route、bit 和真设备验证混为一项。
- `results/route_audit_20261001/verification.json` 是只读审计阶段的 550 文件基线；本轮已授权修改后不再要求当前源码与该旧基线全部相同。
- 并发的其他 JTAG/烧录日志不属于本轮修复的硬件验收证据。

## 后续写代码必须遵守的要求

完整规范见 [FPGA与嵌入式桌面开发规范](07_开发工具与规范.md#doc-001)。以下要求直接进入交接，不因换会话、换模型或交给其他开发者而省略。

1. **FPGA 设计包含 RTL、约束、工具设置和实现结果。** 修改前阅读实际层级、接口、时钟/复位与最新报告；修改后的验收同时包含功能、综合推断、资源、CDC/RDC、时序和布线，不能只交出可编译源码。
2. **先画出实际硬件，再写 HDL。** `for/generate` 通常展开并行硬件；动态索引、part-select、移位、大型 case、除法和取模可能产生 MUX、barrel shifter 或长逻辑链。大型循环不能照搬 CPU 软件写法。常量小循环和小选择器不机械禁止，以真实网表判断。
3. **存储按端口设计。** 大型 memory 优先可靠的同步 BRAM 模板；异步读取只有在确需当前周期读且容量适合时采用 LUTRAM。不得对大数组循环 reset。分析深度、位宽、读写端口、字节使能、读写碰撞与有效性，再依据 report_ram_utilization/primitive 确认推断。多字节写先判断是否需要分 bank，不默认用 FF 实现。
4. **7-Series 重点检查 Slice packing 和 control sets。** 状态/FSM/协议必须正确复位；无需初值的数据管线和 memory 用 valid 管理。避免每个元素不同 CE/reset，引起控制集合碎片化；检查实际 reset/enable/valid 扇出。不能只看 LUT 利用率。
5. **CDC 与存储所有权必须明确。** 单位电平使用同步器、脉冲使用 toggle/握手，多位控制用稳定数据握手，连续流用异步 FIFO。源端数据先寄存，同步器采用 ASYNC_REG；异步复位在各域同步释放。跨域不能直接广播大总线和 ack；结果发布、消费和缓冲区回收有完整协议。
6. **长组合链在具体位置拆分。** 例如 MUX→MUL→ADD→COMPARE 应在取数、乘积或和之后插寄存器，并对齐 valid/标签。每次写清增加的周期/纳秒、首包延迟、稳态吞吐、背压和边界行为。不得增加整帧积压解决小逻辑时序，也不得靠错误 false path/multicycle 隐藏失败。
7. **接口宽度按带宽设计。** 数千位跨模块接口优先评估同步 RAM 地址读口或 data/valid/ready 流。改接口时保持快照一致性、CRC、序号、字节顺序和配置 active/shadow 语义；逐字节/逐像素差分验证。计数器与算术位宽按实际范围，不滥用 32/64 位或 integer 数据路径。
8. **HDL 与软件分工不同。** FPGA 使用有界缓存、有限状态机和硬件流水线；嵌入式 Linux 使用驱动所有权、有限队列、最新完整帧、非阻塞 I/O 和明确的磁盘/断线处理；桌面/树莓派可做表面重建与界面，但原型性能不等于板上完成。FPGA 整数处理与红青 AR、多视角数字孪生分别交付、分别验收。
9. **验证先轻后重，避免盲目重跑。** syntax/elaboration→有意义的边界/碰撞/背压/复位仿真→模块综合/RAM与资源→整机预检查→CDC/约束→布局/拥塞→路由→板测。复用没有变化的 IP，16 线程参数、两个工程依次构建，所有构建统一显示监视器；未通过结构门限不再长时间试 route。
10. **保持工作区与证据。** 只改活动新工程，旧项目/来源快照不动；修改前保存原字节/哈希。RTL/XDC 为 GBK/CP936 无 BOM，文档 UTF-8 无 BOM。所有 Markdown 放 docs，根 README 只索引；普通开发不自动提交推送。遇到持续 15 分钟未解决的问题，将现象、试错、已排除方向和可执行下一步写入 LONG_RUNNING_ISSUES。

## 最新验证结果补充

- C1 before/after OOC 综合退出 0：FF **31,826→19,540**（减少 12,286），LUT **7,629→4,505**（减少 3,124），**12 个 RAMB18E1**（6 个 BRAM Tile）；12 个 bank 的 WRITE_MODE_A/B 均为 READ_FIRST。以上是同条件模块综合，尚不是整机利用率或布线提速测量。
- packet bank 差分重试退出 0：checks=11,981，base_bytes=5,135，full_bytes=4,900，stalls=1,646，reset_cycles=18，32/1/0 目标 ack 各 6 次。独立既有协议自检退出 0，PASS m3tl_full，81 checks。
- projector_viewport 串行重试退出 0：800/+0 与 640/+80 的普通坐标、超出旧视口与右下边界三组检查通过；这不替代真实标定。
- 3 个小 memory 差分模拟已打印 PASS，checks=20,745、雷达 672 字节、栅格 826 字节，但第一次包装 Tcl 在 stdout 收尾出错，入口退出 1；正在串行复试确认正常出口。

### 最后收齐的模块结果（覆盖上文待确认状态）

- 小 memory 差分复试已正常 EXIT 0；before/after 六次 OOC 综合也均成功。Tcl 已用 proc 隔离局部变量；深目录 CWD 的库/临时脚本访问错误仍出现，改用 `C:/Users/ASUS/Desktop/FPGA/.vivado_tmp/small_ram` 后完成。不能仅据此认定唯一根因是路径长度，后续构建优先短 CWD，并保留失败日志。
- 最终小 memory 证据：`results/route_audit_20261001/small_ram_fix/{equivalence_retry2_console.log,synthesis_shortcwd_console.log,resources.tsv}`。

| 模块 | FF 修改前→后 | LUT（报告口径）修改前→后 | 实际存储 |
|---|---:|---:|---|
| perception_regs（C1） | 31,826→19,540 | 7,629→4,505（Slice LUT） | 12 RAMB18E1 |
| 基础版 m3tl_tx | 4,533→425 | 2,082→461（Slice LUT） | LUTRAM，LUT as Memory=96 |
| full m3tl_full_tx | 5,326→801 | 3,755→2,014（Slice LUT） | LUTRAM，LUT as Memory=228 |
| radar_stream | 4,820→120 | 1,870→90（LUT primitive） | 120 个 distributed RAM primitive |
| grid_reader | 3,389→54 | 1,665→120（LUT primitive） | 96 个 distributed RAM primitive |
| m3tl_targets（仅 d2 部分） | 4,978→3,949 | 1,226→951（LUT primitive） | 54 个 distributed RAM primitive |

表内模块为独立同配置前后综合；不同工程和实例不能直接全部相加为整机节省量。LUT primitive 与 Slice LUT/包含 LUTRAM 的报告口径不同，勿混为一列总数。

### 已启动整机门限检查

- `full_storage_preflight` 已启动，只综合和报告 setup 路径，模式 `acx750_full preflight`；不布局布线，不生成 bit。
- 日志：`vivado_project/logs/full_storage_preflight_console.log`；真实状态通过 `vivado_project/logs/build_jobs` 对应 JSON 和 `acx750_full.runs/synth_1/runme.log` 查找，不能把本段“已启动”写为通过。
- CWD：`C:/Users/ASUS/Desktop/FPGA/.vivado_tmp/full_preflight`；统一 run_build 入口、16 线程参数，原工程报告 reset 前自动归档。

## 最终整机结果与下轮操作

| 工程 | 综合预检查 | WNS | Critical Warning | LUT | FF | BRAM Tile | DSP |
|---|---|---:|---:|---:|---:|---:|---:|
| acx750 | EXIT 0 / PASS | +0.964 ns | 0 | 3,293 | 4,079 | 4 | 3 |
| acx750_full | EXIT 0 / PASS | +0.964 ns | 0 | 37,481 | 52,954 | 64.5 | 76 |

本表为修改后**整机综合**，不是布局/路由时序和 Slice packing。旧的基础版 bit 不包含本轮相机和缓存修改；full 仍无本轮合格 bit。不能用此前的板测覆盖新源码。

- 整机证据：`vivado_project/logs/{base_camera_storage_preflight_console.log,full_storage_preflight_console.log}`；两工程根目录的 `synthesis_timing.rpt`、`synthesis_critical_paths.rpt`、`monitor_synthesis_utilization.rpt` 及 `.runs/synth_1` 报告/DCP。旧报告已在 reset 前保存到 `vivado_project/logs/archive`。
- 原始证据核验：3 份 memory 的 `*_original.sv` 是供差分实例化的模块重命名副本；已另存 `*_before_raw.sv`，逐一还原并确认 SHA256 与修改前记录匹配。不要把重命名副本当原始字节。当前 11 份修改的活动 RTL 哈希与原始核验在 `results/storage_repair_20261001_manifest.json`，归档入口 EXIT 0。
- 所有本轮 module 仿真/综合均已收齐。仍缺两个 camera_source 顶层仿真：初次完整 source 集合加载失败，本轮通过了整机综合层次检查，但不能将其写成 CAMERA/AR 切换功能仿真通过。

### 下次从这里直接继续

1. 先阅读总交接顶部、本文件的编码要求和最后结果；检查工作区变更，间隔数小时按同步规则检查远端，不自动推送。
2. 优先完成 C2：畸变 active/shadow 存储改同步双 bank RAM，提供地址、有效标签和下一拍数据；提交/部分修改/克隆写冲突有完整所有权。同步读对 projector 的地址/四邻点采样调度和 AXI 响应进行对拍，保留原精度。
3. 完成 C3：目标记录 RAM 的字段/nearest 写口、字节读口和 100→125 MHz 发布/ack 握手，移除 4,128 位广播。最后 pending 捕获写排空后才发布，消费期间不覆盖，CRC/序号/饱和与旧协议对拍。
4. 两工程依次做布局检查，再读取实际 Slice、control sets、high fanout、拥塞和关键路径。确认本轮资源下降确实改善 packing，不直接复用旧 physopt/route 结论；只有满足结构/时序门限才继续 route。
5. 补 DVP 完整帧计数/时间戳 CDC、三缓冲完整帧所有权和视频网络传输；相机状态仍非真实帧计数，必须先修再板测。OV5640 标定无效时仍只显示 HUD。
6. 路由后 WNS/WHS≥0、DRC/CDC/引脚门限通过才生成新候选 bit；随后检查真实雷达、底盘、OV5640、TFT 和录制。采集、板上 AR 与多视角数字孪生分别记录验收。

下一轮命令从项目根目录执行：通过 `tools/run_build.py` 调用 `tools/scripts/build_750.tcl -tclargs <acx750或acx750_full> preflight`，继续修改后重新综合；不要把本轮 preflight 直接视为允许跳过 CDC/布局检查的 bit 发布。

---

<a id="doc-014"></a>

## 来源：时序修复归档_2026-10-01.md

# 时序修复停工归档：2026-10-01



本次按用户要求停止开发；综合预检查自然结束，未启动新的实现。此文为本轮最终状态，优先于此前“正在构建”记录。



## 结果



| 工程 | 最新证据 | bit / 硬件状态 |

|---|---|---|

| acx750 基础版 | 路由 WNS +0.705 ns、WHS +0.028 ns、DRC Error/Critical Warning=0 | bit 已生成；未上板验证 |

| acx750_full 完整版 | 本轮综合预检查 WNS -0.742 ns、Critical Warning=0、退出码1；耗时约5分47秒 | 预检查拦截；本轮未布局布线，无合格 Full bit |



Full 本轮资源：LUT 57099 (42.42%) | FF 90481 (33.61%) | BRAM 63.5 (17.40%) | DSP 81 (10.95%)。比例按 Vivado 本轮报告，不混用上轮路由资源。综合 hold 尚不能当作路由 hold 结论。



基础 bit 在 `../vivado_project/acx750/acx750.bit`，SHA256 `a7da8089c9bafd762c9cb42497bbbfa86a8595fd51b4943285648a3d92b6fc16`。保留在原工程位置，不移动 IP、runs、生成源或已验证候选。



## 已完成修改与验证



- 两套新工程用三路独立 XPM 异步 FIFO 跨到100MHz DDR写时钟，移除跨区时钟MUX；此前写桥传输、背压、溢出、阶段清空及复位测试通过。

- 两套新工程修正 MDIO 生成时钟来源与千兆 PHY speed 配置；基础工程内部 no_clock 和 unconstrained_internal_endpoints 均归零。

- Full 栅格地址除100改成注册偏移/乘5243/右移19；0–5999逐值比较完全一致，6600边界点与4越界点仿真通过。

- Full 底盘范数除5改成有界乘52429/右移18，再用注册 norm_speed 进行滤波；65536个输入商逐值一致，极端速度、最大dt、余数和断流TB通过。

- Full 将 uptime_ms 到 now_us 换算注册，增加10ns延迟；AR年龄保守+1移到32拍转换的第一拍。AR包装三帧透传回归通过；这不等于年龄饱和边界、发布竞争或真实目标对齐专门测试全部通过。

- AR握手稳定快照总线以寄存器端点限定60ns数据路径，依据3级请求同步器后最早90ns采样；活动像素逻辑仍单周期。未添加全局 false_path。

- 通用编译监视器显示资源、关键错误和日志，保存任务快照、排除旧报告，并检测失联进程。进程无退出记录时显示未知，不伪造退出码。

- 构建增加综合预检查、布局 WNS<-0.5ns早停、未变综合/IP缓存复用；路由达标跳过后优化，明显不达标不长时间尝试。新快速流程本轮在综合 -0.742ns 时正确停止。



## 下一步：具体怎么做



1. 先阅读总交接和同步规则，只修改 `vivado_project/acx750_full` 活动源；不改旧工程、source_snapshot、可研；继续保留基础bit恢复基线。

2. 打开本轮 `synthesis_critical_paths.rpt`。最差路径从 `u_percep_regs/cfg_reg[0][16]` 到 `u_ar/u_engine/grid/plane_sum_reg[95]`，周期10ns，数据延迟10.580ns，逻辑8.146ns/布线2.434ns，18级逻辑。前10条最差均属于这个平面求和。

3. 在 lidar_grid 中把 nx*x、ny*y、nz*z 分别注册，再分拍做求和；保证符号扩展和原96位精度一致。点坐标、距离平方、ROI、输入计数和scan切换必须保持同一点对应关系；调整握手和状态后验证同格连续点、地面阈值、负坐标、40000点溢出。

4. 添加定向地面平面边界/极端系数对拍，重跑栅格与AR回归；不能只测默认水平地面。年龄饱和/新结果发布/旧目标撤框仍需专门测试。

5. 通过 `tools/run_build.py` 调用 `tools/scripts/build_750.tcl -tclargs acx750_full preflight`，只综合。先看退出码及10条关键路径；WNS<0或Critical Warning>0不进入实现。NEEDS_REFRESH检测本轮已执行；不无条件重置所有IP。

6. 预检查通过再调用同一脚本的 implement 模式，复用未改变综合。布局早停规则故意保守；若只剩少量布线问题，可根据报告评估一次有限策略试验，不能无限重复完整实现。

7. 生成候选仍要求真实路由WNS/WHS非负、无DRC Error/Critical Warning。还要补查 bus skew（本轮工具有提醒）、外部IO时序覆盖、CDC、板级摄像头/雷达/底盘联调。综合结果不是上板结果。



## 尚未解决与已排除



- 尚未解决：地面平面乘加路径。本轮约77%数据路径延迟来自逻辑，优先流水线，不能只加实现线程或切换策略。

- 已排除/已解决：BUFGMUX跨区放置、MDIO无时钟、栅格动态除法、底盘重复除法。不能据此声称全部功能完成。

- Full v3 路由 WNS -1.648ns，长时间后优化只到 -1.503ns；其进程在生成报告阶段结束且无正常退出记录，真实退出原因未知。不得称为时序成功，也不得推断硬件坏了。

- 基础版仍有外部 no_input_delay=18/no_output_delay=35 和厂商 RAM/FIFO reset 警告；需核对手册与实测，未用全局降级DRC掩盖。

- 当前Vivado2020.2/7A200T不能直接套用UltraScale的IDR流程；策略探索可能更慢。先修RTL和约束。

- 两套工程均未完成本轮ACX750实板/真实传感器验收；底盘发送订阅及控制、标定、用户界面、移动数字孪生等后续仍按待办清单推进。



## 归档入口



- [证据与代码快照](../vivado_project/logs/archive/timing_closeout_20261001_061237/manifest.json)：每项路径、大小、SHA256。保存本轮关键RTL/XDC/脚本和报告，不是完整Vivado可独立重建工程；完整项目依赖仍在活动工程中。

- 原始日志留在 `vivado_project/logs`；Vivado `.runs/.srcs` 不搬动。资料没有推送GitHub，没有删除历史记录。

- 所有说明Markdown放docs，根目录只保留README索引。手写RTL/XDC仍GBK无BOM，Markdown/Python/JSON用UTF-8无BOM。

## 2026-10-06 Full 配置区 BRAM 候选完成，按5%额度线停工（最新）

### 当前范围与成果

- 当前AGENTS更新已采用：优先复用已有实现/测试，按真实硬件结构与工具结果工作。本轮借鉴只读AC880 `perception_regs_ram.sv` 中双银行BRAM表结构及现有AXI exerciser，在Full原 `perception_regs` 的基础上只替换畸变LUT；保留Full原32拍对象快照、metadata/record_valid语义。未改AC880/通信版/厂商原件。
- 候选位于 `results/full_lut_bram_20261006/perception_regs.sv`，原始字节备份 `perception_regs_baseline.sv`。**活动Full RTL本轮未合入这个候选；活动工程仍含上轮遥测CDC修复。** 7072位LUT接口仍在活动工程中；本轮没有新bit或硬件操作。
- 综合前根因检查：现有物理报告level5/128%拥塞窗口99%是u_percep_regs。旧LUT shadow/active各221×32，共14144位寄存器，reset整表、提交并行复制，再用7072位跨模块总线与221:1动态选择，产生大量互连/CE/复位负载。不是只看整体LUT百分比。
- 候选：两份221×32同步双口BRAM（投影读A、AXI/克隆B），银行切换实现LUT原子更新；移除整表寄存器reset和提交复制，初始按221拍清零，提交后442拍复制新active到shadow以保留后续部分写语义。64字配置寄存器暂保持旧结构。

| 同条件模块级OOC综合 | 旧版 | 候选 | 变化 |
|---|---:|---:|---:|
| LUT | 4264 | 1509 | -2755 |
| FF | 19557 | 5272 | -14285 |
| RAMB36 | 0 | 2 | +2 |
| RAMB18（原对象快照） | 12 | 12 | 0 |
| DSP | 0 | 0 | 0 |
| control sets | 1151 | 268 | -883 |
| 最大逻辑驱动扇出 | 19308 | 5168 | 明显下降 |

- 仿真PASS：226写、652读，221个LUT字全覆盖，两次commit、银行克隆后的部分写、独立AW/W、B/R背压、查表和复位、完成后的metadata/目标读回。`FULL_LUT_RAM_PASS`。没有证明快照并发读的逐周期等价。
- 候选综合内部路径WNS +5.516ns、WHS +0.262ns；未设置模块外边界IO延迟，所以只代表内部路径。未布局布线/完整工程资源检查/CDC签核，不能声称整机拥塞已解决。
- 首次candidate.log仿真编译失败：生成候选时CRLF文本替换遗漏两条旧lut/lut_shadow循环。统一候选换行并移除遗漏后重跑candidate_retry.log，EXIT0。原失败日志保留，非人工改测试状态。
- 基线baseline.log EXIT0，候选candidate_retry.log EXIT0；资源对比 `comparison.json` 和两目录utilization/fanout/control_sets/timing报告。所有调用走tools/run_build.py，20线程。

### 接口和延迟变化（下一步必须验证）

- LUT从7072位展开输出改为8位lut_index输入、32位lut_word同步输出。地址/数据在100MHz控制域，不新增CDC。
- INIT阶段AXI AW/W/AR暂停，221拍约2.21us；commit在config_safe时交换银行，随后442拍约4.42us克隆期间新写/读暂停、config_pending保持1。cfg_bridge必须通过ready等待，不能假设一拍响应；需要检查其timeout和命令间隔。
- 现有投影器第12状态连续采四个异步LUT样本，接同步表必须在每个新地址后增加一拍等待，包括首地址。预计每角4拍、每对象8角共32拍=0.32us，32对象总10.24us；实际周期由对拍确认。视频吞吐/像素延迟不修改，不增加整帧缓存。
- 旧配置允许pending期间继续写shadow，候选用AXI背压限制pending期间新事务，属于事务时序变化，需明确验收；外部地址、数据格式、WSTRB、BRESP/RRESP、默认值不变。不要直接宣称逐周期协议等价。

### 下次按此顺序继续

1. 先读此条和LONG_RUNNING_ISSUES，按同步规则fetch并核对本地修改；本轮fetch后HEAD与origin/main差异0/0，无提交/推送。
2. 对同步读口制作投影候选，在每个LUT新地址后加等待拍；同输入与旧异步读投影器比较最终box_valid/x/y/disparity/nearest/risk，覆盖非零正负LUT、0/1/32目标、边界/失效/复位，记录实际新增周期。不能仅用零LUT测试掩盖错位。
3. 候选通过后才改标准Full中的perception_regs、perception_engine、video/acx750_ar_wrap、fixed_projector和rtl/acx750_full_top，移除pr_lut超宽接口。用小补丁接lut_index/lut_word；保持遥测CDC修复，不覆盖本轮之外的修改。
4. 检查cfg_bridge对INIT/commit-clone背压的等待/超时，并补实际配置命令联合仿真；验证config_safe保证投影期间银行不切换，metadata/对象快照读和warm reset。
5. Full顶层展开、整机综合、资源/control set/fanout和实际XPM指针约束审计，再place/phys_opt并检查拥塞门禁。复位全局扇出/剩余cfg网络仍需物理结果判断。只在门禁合格后route一次；路由WNS/WHS>=0及DRC/源码哈希验收后生成新bit。
6. bit完成再通知用户上电，30秒连续四类遥测检查，重复S0与雷达重启等待；安装位置仍未定，不验收投影标定准确性，底盘仍未测。

停工依据：本轮最后查询五小时used95%=剩余5%，每周used56%=剩余44%。停止新工作，运行中的模块基线综合已正常完成，当前本轮无编译待收尾。板卡/雷达继续不用上电，HDMI拔掉避免反向供电。


## 2026-10-07 Full BRAM 优化已合入，整机综合预检查运行中（最新）

- 标准活动工程仅 `vivado_project/acx750_full/acx750_full.xpr`。已按同步规则fetch，HEAD/origin/main为0/0，未pull覆盖本地修改，未提交/推送。通信版/AC880/旧工程/厂商原件未改。
- 已合入5个活动RTL：perception/perception_regs.sv、fixed_projector.sv、perception_engine.sv、video/acx750_ar_wrap.sv、rtl/acx750_full_top.sv。移除7072位LUT广播，改8位地址/32位同步数据；上一轮遥测CDC修复仍保留。备份及活动哈希 `results/full_lut_integration_20261007/{before_integration,active_hashes.json}`。
- 投影器每个新LUT地址后等待一拍（状态31），候选对旧异步参考逐结果对拍通过。非零正/负畸变，0/1/32目标、越界、低深度、未标定、中途复位：box_valid、有效框坐标、disparity、nearest/risk一致。正常1目标2377→2409拍、32目标76033→77057拍，即每目标32拍/0.32us、32目标10.24us；深度被拒和未标定时无额外查表拍。未改变视频像素通路，不增加帧缓存。
- 实际cfg_bridge与BRAM寄存器联合仿真通过，复用原testbench增加INIT/CLONE背压、提交克隆时发送新写/读、两次银行切换和克隆中复位。桥无内部事务timeout，AW/W/AR会等待ready；测试验证221拍初始化和442拍克隆不会导致该桥报错。**桥执行命令时没有输入ready且不能收另一个并发包，主机仍须按已有配置协议串行发送/等回读；不宣称任意速率配置无丢包。**
- 标准工程Full顶层RTL展开EXIT0，确认新LUT接口与遥测桥均在实际层级；原工程的tb_ar_wrap和tb_cfg_bridge接口同步更新。候选对拍脚本已改引用活动RTL，保留旧参考作对照。
- 本轮调用均经tools/run_build.py图形监视器，20线程。当前任务 `full_bram_synthesis_preflight`，日志 `results/full_lut_integration_20261007/full_preflight.log`，执行 `build_750.tcl acx750_full preflight`，只综合/审计，不自动进入布局布线。新增综合control_sets/fanout/cdc/methodology报告。旧run报告先归档 `vivado_project/logs/archive/acx750_full_pre_reset_1791343543917`。
- 10-06模块级对照4264→1509 LUT、19557→5272 FF、1151→268控制集、最大逻辑扇出19308→5168、增加2 RAMB36是局部证据；本轮整机资源/时序未完成，不能套算。
- 没有新bit，旧bit不含最新修复且源码哈希门禁拒绝加载；未进行JTAG/硬件操作，板卡/雷达暂不需要上电，HDMI避免反向供电。

下一步：收整机preflight真实结果→检查资源/高扇出/CDC/TIMING-24，特别是现有clock_groups是否覆盖XPM Gray约束→满足条件再一次place/phys_opt检查物理结构门禁→只在拥塞/资源/时序与约束可接受时route→路由WNS/WHS>=0和DRC/哈希验收后新bit。不要未经审查直接运行build_hdmi_pair.py跳进整机route。板上30秒四类遥测连续/重复S0/雷达重启等待及真实投影/底盘均待验。

测试证据：`results/full_lut_integration_20261007/projector_retry.log`、`projector_test/project/projector_test.sim/sim_1/behav/xsim/simulate.log`、`cfg_test.log`、`cfg_test/project/cfg_test.sim/sim_1/behav/xsim/simulate.log`、`full_elaboration.log`。第一次投影Tcl错误用了perception子目录内不存在的头文件，修正到imports/perception_types.svh并重跑通过，失败日志保留。


## 2026-10-07 Full 整机预检查与复位扇出修复（过程记录，结果以上方为准）

- 修改对象仍是标准 `vivado_project/acx750_full/acx750_full.xpr`；未修改通信版、旧工程或厂商原件。最新活动RTL含BRAM LUT、同步投影与遥测完整包CDC。
- 第二轮整机综合 `full_registered_reset_preflight` 已完成 EXIT0：38263 LUT、36166 FF、62 RAMB36、20 RAMB18、76 DSP、1395 control sets；setup WNS +0.964 ns。这是综合阶段数据，不是路由/板上签核。
- 复位直接进入XPM FIFO顺序数据引脚的Critical项已消除；总CDC-1仍37、CDC-10仍9、CDC-13仍19，不能声称整体CDC通过。组合异步复位源和既有雷达/相机路径仍需分别审查。
- 发现两个同源同拍的新增复位同步器被合并，最大扇出9486。只在u_rst_cfg、u_rst_percep两个小同步器实例设置DONT_TOUCH，保留两个实际复位树；不是全局禁止优化。正常数据延迟不变，复位释放仍额外2个系统周期。正在用整机综合确认是否有效，未凭RTL宣称扇出已下降。
- 新增audit_full_packet_fifo.tcl：检查实际复位分组和Gray指针端点、bus_skew与FIFO未知D引脚CDC。第一次脚本误以为只有两组11位指针，实测42位；核对安装的XPM 2020.2源码655-717行后，改为逐组检查普通10位和扩展11位指针各两个方向。保留失败日志，不将检查失败当成硬件问题。
- build_750.tcl新增phys模式，复用标准工程、20线程、现有post-step门禁；只到phys_opt_design，不进入route、不生成bit。原单参数入口保持build默认。
- 当前full_preserved_reset_preflight运行中，日志results/full_lut_integration_20261007/full_preserved_reset_preflight.log。完成后：读取资源/扇出→跑FIFO约束审计→有界place/phys评估→满足门禁才route。
- 旧bit仍不含最新修改且哈希门禁拒绝加载。没有板测；暂不需要板卡和雷达。投影额外延迟最多10.24us，视频像素延迟未增加。

# 2026-10-08 双摄采集子系统结构审查与局部验证

- 活动工程：vivado_project/acx750_stereo_basic，规范XPR；当前处理核心顶层stereo_pair_engine，采集通过stereo_dual_capture独立OOC检查。两者尚未整机连接，资源不得简单相加后宣称板级余量。
- 两路18×2048异步FIFO使用BRAM，每路独立PCLK，系统100MHz；控制50MHz。数据跨域由XPM FIFO承载，配置/故障由单bit同步器承载，异步复位同步释放。初始化完成条件先源域寄存再两级同步，消除CDC-10，增加2FF及20ns状态延迟，像素通路不增加延迟。
- 无大型组合遍历/整存储清零。帧计数按实际尺寸限定；坏帧靠协议有效性拒绝，末像素等待END。640×480 RGB565原始FIFO每路约4KiB，不能替代整帧缓存或承担无界背压。
- 局部综合：779 LUT、1600 FF、3 BRAM36等效、0 DSP。各域最大路径余量：sys100MHz +5.978ns、ctrl50MHz +16.085ns、两PCLK按25MHz参考预算 +35.865ns。未布局估算，没有板级input/output delay、实际PCLK测量及最终generated_clock验证，不能称时序收敛。
- CDC报告：两处CDC-10修复后消失；XPM复位宏仍有5处CDC-26。OOC SCCB内部三态有2条Synth8-5799警告，整机必须把SDA通过顶层IOBUF实现并复查，不能忽略后直接生成bit。
- 四项XSim回归PASS：双目参考、缓存所有权、双PCLK采集、初始化超时重试。日志vivado_project/logs/stereo_basic_regression.log；采集报告vivado_project/logs/stereo_basic/capture_synthesis/。初始化成功SCCB及真实曝光同步尚未验证。
- 后续优先修SOF时间关联，再接灰度/标定与DDR/RGB。显示采用原800×480小梅哥RGB LCD，旧HDMI安排不再用于此新工程。整机门禁通过前不进入布线或发布bit。
