//============================================================================
// acx750_eth_tx_arb -- 发送仲裁（ARP 原始帧 / UDP 遥测 → 唯一 PHY）
//
// 两路复用：
//   路 0 (p0)：ARP 原始以太网帧，交给 acx750_eth_raw_tx
//   路 1 (p1)：UDP 遥测帧，交给厂商 eth_udp_tx_gmii
// 仲裁策略：ARP 优先。任一路发送中，另一路的请求会排队等待。
//
// 对外接口按父模块冻结的端口给出 8bit GMII（gmii_txd/gmii_txen）与
// gmii_tx_clk（= clk125m）。GMII→RGMII 的 ODDR 转换由顶层用厂商
// vendor_ref/eth_tx/gmii_to_rgmii.v 完成：
//     gmii_to_rgmii u(.gmii_tx_clk(gmii_tx_clk), .gmii_txd(gmii_txd),
//                     .gmii_txen(gmii_txen), .gmii_txer(1'b0), ...);
//
// bug 提示：p0_busy 与 p1_busy 都是本模块输出，顶层不要把其中任何一个和
// 其它模块的输出接到同一个 wire 上（当前草稿顶层把 p1_busy 与 m3tl.tx_busy
// 接到了同一根线，需要顶层自己分开）。
//============================================================================
`timescale 1ns/1ps

module acx750_eth_tx_arb (
  input  logic        clk125m,
  input  logic        rst_n,

  // 路 0：ARP（原始帧）
  input  logic        p0_start,
  input  logic [15:0] p0_len,
  output logic [15:0] p0_idx,
  input  logic [7:0]  p0_val,
  output logic        p0_busy,

  // 路 1：UDP 遥测（交给厂商 eth_udp_tx_gmii）
  input  logic        p1_start,
  input  logic [15:0] p1_len,
  input  logic [47:0] p1_dst_mac,
  input  logic [47:0] p1_src_mac,
  input  logic [31:0] p1_dst_ip,
  input  logic [31:0] p1_src_ip,
  input  logic [15:0] p1_dst_port,
  input  logic [15:0] p1_src_port,
  output logic        p1_req,
  input  logic [7:0]  p1_payload,
  output logic        p1_busy,

  // 到 PHY（GMII）
  output logic        gmii_tx_clk,
  output logic [7:0]  gmii_txd,
  output logic        gmii_txen
);

  typedef enum logic [1:0] {
    A_IDLE = 2'd0,
    A_ARP  = 2'd1,
    A_UDP  = 2'd2
  } astate_e;

  astate_e st;

  logic        p0_pend, p1_pend;
  logic [15:0] p0_len_l, p1_len_l;

  logic        raw_start;      // 组合脉冲
  logic        udp_pulse;      // 组合脉冲
  logic        raw_start_r;    // 打一拍后送给 raw_tx / udp
  logic        udp_pulse_r;
  logic [15:0] raw_len_r;

  //--------------------------------------------------------------------------
  // 路 0：ARP 原始帧发送器
  //--------------------------------------------------------------------------
  wire [15:0] raw_idx;
  wire [7:0]  raw_txd;
  wire        raw_txen;
  wire        raw_busy;

  acx750_eth_raw_tx u_raw (
    .clk125m  (clk125m),
    .rst_n    (rst_n),
    .start    (raw_start_r),
    .frame_len(raw_len_r),
    .byte_idx (raw_idx),
    .byte_val (p0_val),
    .busy     (raw_busy),
    .gmii_txd (raw_txd),
    .gmii_txen(raw_txen)
  );

  //--------------------------------------------------------------------------
  // 路 1：厂商 UDP 发送器
  //--------------------------------------------------------------------------
  wire [7:0] udp_txd;
  wire       udp_txen;
  wire       udp_clk;
  wire       udp_done;
  wire       udp_req;

  eth_udp_tx_gmii u_udp (
    .clk125M      (clk125m),
    .reset_n      (rst_n),
    .tx_en_pulse  (udp_pulse_r),
    .tx_done      (udp_done),
    .dst_mac      (p1_dst_mac),
    .src_mac      (p1_src_mac),
    .dst_ip       (p1_dst_ip),
    .src_ip       (p1_src_ip),
    .dst_port     (p1_dst_port),
    .src_port     (p1_src_port),
    .data_length  (p1_len_l),
    .payload_req_o(udp_req),
    .payload_dat_i(p1_payload),
    .gmii_tx_clk  (udp_clk),
    .gmii_txen    (udp_txen),
    .gmii_txd     (udp_txd)
  );

  //--------------------------------------------------------------------------
  // 仲裁组合逻辑：登记请求 + 选择授权
  //--------------------------------------------------------------------------
  astate_e     st_n;
  logic        p0_pend_n, p1_pend_n;
  logic [15:0] p0_len_n, p1_len_n;

  always_comb begin
    st_n      = st;
    p0_pend_n = p0_pend;
    p1_pend_n = p1_pend;
    p0_len_n  = p0_len_l;
    p1_len_n  = p1_len_l;
    raw_start = 1'b0;
    udp_pulse = 1'b0;

    // 新到的请求先登记（同一路只保留一个待发请求）
    if (p0_start) begin
      p0_pend_n = 1'b1;
      p0_len_n  = p0_len;
    end
    if (p1_start) begin
      p1_pend_n = 1'b1;
      p1_len_n  = p1_len;
    end

    case (st)
      A_IDLE: begin
        if (p0_pend_n) begin                 // ARP 优先
          raw_start = 1'b1;
          p0_pend_n = 1'b0;
          st_n      = A_ARP;
        end else if (p1_pend_n) begin
          udp_pulse = 1'b1;
          p1_pend_n = 1'b0;
          st_n      = A_UDP;
        end
      end
      A_ARP: if (!raw_busy) st_n = A_IDLE;
      A_UDP: if (udp_done)  st_n = A_IDLE;
      default: st_n = A_IDLE;
    endcase
  end

  //--------------------------------------------------------------------------
  // 状态与脉冲寄存
  //--------------------------------------------------------------------------
  always_ff @(posedge clk125m or negedge rst_n) begin
    if (!rst_n) begin
      st          <= A_IDLE;
      p0_pend     <= 1'b0;
      p1_pend     <= 1'b0;
      p0_len_l    <= 16'd0;
      p1_len_l    <= 16'd0;
      raw_start_r <= 1'b0;
      udp_pulse_r <= 1'b0;
      raw_len_r   <= 16'd0;
    end else begin
      st          <= st_n;
      p0_pend     <= p0_pend_n;
      p1_pend     <= p1_pend_n;
      p0_len_l    <= p0_len_n;
      p1_len_l    <= p1_len_n;
      raw_start_r <= raw_start;
      udp_pulse_r <= udp_pulse;
      if (raw_start)
        raw_len_r <= p0_len_l;              // 用已登记的待发长度，保证与被授权的请求一致
    end
  end

  //--------------------------------------------------------------------------
  // 到 PHY 的 GMII 输出：按当前授权路做二选一
  //--------------------------------------------------------------------------
  wire udp_sel = (st == A_UDP);

  assign gmii_tx_clk = clk125m;
  assign gmii_txd    = udp_sel ? udp_txd  : raw_txd;
  assign gmii_txen   = udp_sel ? udp_txen : raw_txen;

  //--------------------------------------------------------------------------
  // 对外状态 / 握手
  //--------------------------------------------------------------------------
  assign p0_idx = raw_idx;
  assign p0_busy = raw_busy;
  assign p1_req  = udp_req;
  assign p1_busy = (st == A_UDP);

endmodule