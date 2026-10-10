//============================================================================
// acx750_radar_stream -- 雷达字节流 125MHz(以太网域) -> 100MHz(控制域) 适配
//
// 背景（见 docs/recon_880_perception.md §3-GAP-B / §3-GAP-E）：
//   7020 上 MID-360 点云链路是 eth_udp_rx_gmii 的逐字节 payload（已剥 IP/UDP
//   头）经 XPM 异步 FIFO 从 125MHz 搬到 100MHz，再直连 perception_engine 的
//   radar_data/radar_valid/radar_last。750 上不允许用 XPM/IP，故本模块用
//   自己写的双时钟异步 FIFO（格雷码指针 + 2 级同步器）复刻这条链。
//
// 关键点：
//   * 存储字 = {radar_last, radar_data}（9bit），包尾标志作为 sideband 与数据
//     一起穿过 FIFO。绝不能把跨域的 eth_pkt_done 单独打拍去对齐数据流——那样
//     在时钟比/相位变化时会整体错位。
//   * eth_pkt_done 来自 eth_udp_rx_gmii 的 PKT_CHECK 状态，比“最后一个 payload
//     字节”晚好几拍，无法直接贴到那个字节上；因此本模块把写侧延迟一拍，用
//     “当前 eth_valid 已落下”来判定刚才那一拍就是包尾（eth_pkt_done 作为
//     辅助/兜底或参与判定）。eth_udp_rx_gmii 的 payload 字节是连续输出的
//     （RX_DATA 逐拍），故该判定可靠；前置条件：包与包之间至少有一拍 idle
//     （RX_CRC/PKT_CHECK/IDLE 天然保证）。
//   * 写侧溢出时丢字节并让 fifo_overflow_cnt 递增，绝不卡死。
//   * full 只在写侧判断、empty 只在读侧判断；指针用 reg[n:0] 多一位区分满/空。
//
// 接口冻结（见 docs/sensor_datalane_750.md）。
//============================================================================
`timescale 1ns/1ps
module acx750_radar_stream #(
  parameter integer DEPTH = 512          // 存储深度（字），建议 512 或 1024
)(
  // ---- 写侧：以太网域 ----
  input  logic        eth_clk,           // = clk125m
  input  logic        eth_rst_n,         // = rst_eth_n（低有效）
  input  logic        eth_valid,         // 逐字节有效（payload_valid_o）
  input  logic [7:0]  eth_data,          // payload_dat_o
  input  logic        eth_pkt_done,      // one_pkt_done：整包结束单周期脉冲
  // ---- 读侧：控制域（100MHz）----
  input  logic        clk,               // = clk_sys
  input  logic        rst_n,             // = rst_sys_n（低有效）
  output logic [7:0]  radar_data,
  output logic        radar_valid,
  output logic        radar_last,        // 本包最后一个字节
  output logic [31:0] fifo_overflow_cnt  // 写侧溢出丢字节计数
);

  localparam integer AW = $clog2(DEPTH);   // 512 -> 9，指针位宽 = AW+1 = 10

  function automatic logic [AW:0] bin2gray(input logic [AW:0] b);
    bin2gray = b ^ (b >> 1);
  endfunction

  // 存储字：{last, data}。异步读出，综合为分布式 RAM（512x9 很小）。
  (* ram_style = "distributed" *) logic [8:0] mem [0:DEPTH-1];

  //--------------------------------------------------------------------------
  // 写侧：延迟一拍输出，用“valid 落下”判定包尾
  //--------------------------------------------------------------------------
  logic       v_d;
  logic [7:0] d_d;
  always_ff @(posedge eth_clk or negedge eth_rst_n) begin
    if (!eth_rst_n) begin
      v_d <= 1'b0;
      d_d <= 8'h00;
    end else begin
      v_d <= eth_valid;
      d_d <= eth_data;
    end
  end

  logic wr_en;
  logic wr_last;
  assign wr_en   = v_d;                          // 上一拍出现了一个 payload 字节
  assign wr_last = (!eth_valid) || eth_pkt_done; // 当前拍 valid 已落 -> 上一拍是包尾

  //--------------------------------------------------------------------------
  // 写侧指针 / full（只在本域判断）
  //--------------------------------------------------------------------------
  logic [AW:0] wbin, wgray;
  logic [AW:0] rbin, rgray;                      // 读指针（在写域被同步读取）
  logic [AW:0] rgray_s1, rgray_s2;               // 读指针格雷码同步进写域
  logic        full;
  logic [AW:0] wbin_nxt, wgray_nxt;
  logic        full_nxt;                          // full 的下一拍值（组合算、寄存用）

  // ⚠️ full 必须是**寄存器**，不能写成组合赋值。
  //    若写成 assign full = (wgray_nxt == ...)，而 wgray_nxt 又依赖 full，
  //    就构成组合环 `full -> wgray_nxt -> full`：综合报
  //    [Synth 8-295] found timing loop（wgray[8]），仿真表现为**无限 delta 循环、
  //    时间不推进**（xsim 烧 CPU 却原地不动）。Cummings 的标准异步 FIFO 里
  //    wfull 本来就是寄存器，这里照做。
  assign wbin_nxt  = wbin + ((wr_en && !full) ? 1'b1 : 1'b0);
  assign wgray_nxt = bin2gray(wbin_nxt);
  // 满判定：下一个写指针 == 读指针"最高两位取反"
  assign full_nxt  = (wgray_nxt == {~rgray_s2[AW:AW-1], rgray_s2[AW-2:0]});

  always_ff @(posedge eth_clk or negedge eth_rst_n) begin
    if (!eth_rst_n) begin
      wbin              <= '0;
      wgray             <= '0;
      full              <= 1'b0;
      fifo_overflow_cnt <= 32'd0;
    end else begin
      full <= full_nxt;                      // 寄存器化的"满"
      if (wr_en) begin
        if (!full) begin
          // mem 深度是 2**AW，而指针有 AW+1 位：**必须取低 AW 位做地址**，
          // 直接用 wbin 会越界（指针 >= 512 时下标超出数组范围）。
          mem[wbin[AW-1:0]] <= {wr_last, d_d};
          wbin              <= wbin_nxt;
          wgray             <= wgray_nxt;
        end else begin
          fifo_overflow_cnt <= fifo_overflow_cnt + 32'd1;  // 丢字节，不卡死
        end
      end
    end
  end

  always_ff @(posedge eth_clk or negedge eth_rst_n) begin
    if (!eth_rst_n) {rgray_s2, rgray_s1} <= '0;
    else            {rgray_s2, rgray_s1} <= {rgray_s1, rgray};
  end

  //--------------------------------------------------------------------------
  // 读侧指针 / empty（只在本域判断）
  //--------------------------------------------------------------------------
  logic [AW:0] wgray_s1, wgray_s2;               // 写指针格雷码同步进读域
  logic        empty;

  assign empty = (rgray == wgray_s2);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rbin  <= '0;
      rgray <= '0;
    end else if (!empty) begin
      rbin  <= rbin + 1'b1;
      rgray <= bin2gray(rbin + 1'b1);
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) {wgray_s2, wgray_s1} <= '0;
    else        {wgray_s2, wgray_s1} <= {wgray_s1, wgray};
  end

  //--------------------------------------------------------------------------
  // 读侧输出：非空即有效，每拍弹出一个字节（下游 packet_tap 无反压）
  //--------------------------------------------------------------------------
  // 地址同样要取低 AW 位（指针高位只用于满/空判定）
  assign radar_data  = mem[rbin[AW-1:0]][7:0];
  assign radar_last  = mem[rbin[AW-1:0]][8];
  assign radar_valid = !empty;

endmodule