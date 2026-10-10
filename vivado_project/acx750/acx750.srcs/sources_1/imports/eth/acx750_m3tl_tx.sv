//============================================================================
// acx750_m3tl_tx -- M3TL v1 遥测帧组装与节流发送
//
// 协议权威定义：docs/telemetry_protocol.md
// 上位机解码实现：host/m3tl.py（本模块产出的字节必须能被它正确解出）
//
// 32 字节帧头（全部小端）：
//   偏移 0..3   magic "M3TL"
//   偏移 4      version = 1
//   偏移 5      type
//   偏移 6..7   flags（保留，填 0）
//   偏移 8..11  payload_len（载荷字节数，不含帧头）
//   偏移 12..15 sequence（每类独立递增）
//   偏移 16..23 timestamp_ms（u64，低 32 位用 uptime_ms，高 32 位 0）
//   偏移 24..27 header_crc32：对偏移 0..23 做 zlib.crc32 一致的小端 CRC32
//   偏移 28..31 payload_crc32：对载荷做同样的 CRC32
//
// CRC 说明（重点）：
//   复用厂商 crc32_d8.v。经 Python 对拍确认其 crc_result 输出与
//   zlib.crc32(已输入字节) 完全一致（厂商内部为"输入按位反转 + 反射多项式 +
//   输出按位反转并取反"，等价于 CRC-32/ISO-HDLC）。因为协议要求小端，
//   所以写进帧里时按 [7:0],[15:8],[23:16],[31:24] 依次摆放。
//   这里用"顺序构建"的方式：逐字节写入帧缓冲的同时把同一字节送入 crc32_d8，
//   帧头 24 字节算完得 header_crc，载荷算完得 payload_crc，全部与字节序无关，
//   不会出现漏算/错位。
//
// 本轮实现：type=1 心跳（16 字节载荷）、type=6 相机状态（12 字节载荷）。
// type=3（目标）、type=5（栅格）见文件末 TODO。
//
// 传给仲裁器的 p1_len 是 UDP 载荷长度 = 32 + payload_len。
//============================================================================
`timescale 1ns/1ps

`include "../acx750_defs.svh"

module acx750_m3tl_tx #(
  parameter int unsigned CLK_HZ       = 125_000_000,
  parameter int unsigned HB_PERIOD_MS = 500,        // 心跳周期
  parameter int unsigned CAM_PERIOD_MS= 1000        // 相机状态周期
)(
  input  logic        clk125m,
  input  logic        rst_n,

  // 板卡状态（用于 type=1 心跳）
  input  logic [7:0]  stat_flags,      // bit0 pll_locked,1 ddr3_done,2 eth_up,3 cam_done
  input  logic [2:0]  stage,
  input  logic [31:0] uptime_ms,
  input  logic [31:0] drop_count,

  // 相机状态（type=6）
  input  logic [31:0] cam_frames,
  input  logic [31:0] cam_last_ms,
  input  logic [15:0] cam_width,
  input  logic [15:0] cam_height,

  // 目的地址
  input  logic [47:0] dst_mac,
  input  logic [31:0] dst_ip,

  // 到仲裁器
  output logic        tx_start,
  output logic [15:0] tx_len,
  input  logic        tx_req,
  output logic [7:0]  tx_payload,
  output logic        tx_busy,

  // 统计
  output logic [31:0] tx_pkt_cnt
);

  // 载荷长度常量
  localparam logic [15:0] HB_PLEN  = 16'd16;
  localparam logic [15:0] CAM_PLEN = 16'd12;
  localparam logic [15:0] HDR_LEN  = 16'd32;

  //==========================================================================
  // 1. 1 ms 时基与节流计数
  //==========================================================================
  localparam logic [23:0] TICK_DIV = CLK_HZ / 1000;   // 每毫秒拍数

  logic [23:0] tick_cnt;
  logic        tick_ms;

  always_ff @(posedge clk125m or negedge rst_n) begin
    if (!rst_n) begin
      tick_cnt <= 24'd0;
      tick_ms  <= 1'b0;
    end else if (tick_cnt == TICK_DIV - 24'd1) begin
      tick_cnt <= 24'd0;
      tick_ms  <= 1'b1;
    end else begin
      tick_cnt <= tick_cnt + 24'd1;
      tick_ms  <= 1'b0;
    end
  end

  logic [31:0] hb_ms_cnt;
  logic [31:0] cam_ms_cnt;
  // 由发送状态机发出的"周期计数清零"脉冲。
  // 注意：计数器只能有一个驱动源——清零必须通过这两根脉冲回灌，
  // 不能在状态机里直接写 hb_ms_cnt/cam_ms_cnt，否则综合会报
  // [Synth 8-6859] multi-driven net（多驱动）。
  logic        hb_clr, cam_clr;

  always_ff @(posedge clk125m or negedge rst_n) begin
    if (!rst_n) begin
      hb_ms_cnt  <= 32'd0;
      cam_ms_cnt <= 32'd0;
    end else if (hb_clr) begin
      hb_ms_cnt  <= 32'd0;               // 心跳已发出，重新计时
    end else if (cam_clr) begin
      cam_ms_cnt <= 32'd0;               // 相机状态已发出，重新计时
    end else if (tick_ms) begin
      // 计到周期值后饱和保持，保证"错过一次也会在下一拍补发"
      if (hb_ms_cnt  < HB_PERIOD_MS)  hb_ms_cnt  <= hb_ms_cnt  + 32'd1;
      if (cam_ms_cnt < CAM_PERIOD_MS) cam_ms_cnt <= cam_ms_cnt + 32'd1;
    end
  end

  wire hb_due  = (hb_ms_cnt  >= HB_PERIOD_MS);
  wire cam_due = (cam_ms_cnt >= CAM_PERIOD_MS);

  //==========================================================================
  // 2. 帧缓冲与构建状态机
  //==========================================================================
  typedef enum logic [3:0] {
    M_IDLE   = 4'd0,
    M_HINIT  = 4'd1,   // 帧头 CRC 复位一拍
    M_HDR    = 4'd2,   // 写帧头 0..23，同时喂 CRC
    M_HLATCH = 4'd3,   // 写 header_crc32（偏移 24..27）
    M_PINIT  = 4'd4,   // 载荷 CRC 复位一拍
    M_PAY    = 4'd5,   // 写载荷，同时喂 CRC
    M_PLATCH = 4'd6,   // 写 payload_crc32（偏移 28..31）
    M_READY  = 4'd7,   // 向仲裁器发 tx_start
    M_SEND   = 4'd8    // 等 tx_req 逐字节吐出
  } mstate_e;

  mstate_e     st;
  // Packet storage is declared as four banks below.  // 32 字节头 + 载荷（预留 512，够放栅格 421）

  logic [7:0]  typ_r;
  logic [15:0] plen_r;
  logic [31:0] seq_r;
  logic [15:0] total_r;
  logic [31:0] seq_hb, seq_cam;

  // 构建期间锁存的状态快照
  logic [7:0]  flags_r;
  logic [2:0]  stage_r;
  logic [31:0] uptime_r;
  logic [31:0] drop_r;
  logic [31:0] cam_frames_r;
  logic [31:0] cam_last_r;
  logic [15:0] cam_w_r;
  logic [15:0] cam_h_r;

  logic [4:0]  hdr_i;    // 0..23
  logic [15:0] pay_i;    // 0..plen_r-1
  logic [15:0] idx;      // 发送下标

  //--------------------------------------------------------------------------
  // 当前帧头字节（组合）
  //--------------------------------------------------------------------------
  logic [7:0] hdr_b;

  always_comb begin
    hdr_b = 8'h00;
    case (hdr_i)
      5'd0:  hdr_b = 8'h4D;              // 'M'
      5'd1:  hdr_b = 8'h33;              // '3'
      5'd2:  hdr_b = 8'h54;              // 'T'
      5'd3:  hdr_b = 8'h4C;              // 'L'
      5'd4:  hdr_b = `M3TL_VERSION;      // 1
      5'd5:  hdr_b = typ_r;
      5'd6:  hdr_b = 8'h00;              // flags[7:0]
      5'd7:  hdr_b = 8'h00;              // flags[15:8]
      5'd8:  hdr_b = plen_r[7:0];        // payload_len LE
      5'd9:  hdr_b = plen_r[15:8];
      5'd10: hdr_b = 8'h00;
      5'd11: hdr_b = 8'h00;
      5'd12: hdr_b = seq_r[7:0];         // sequence LE
      5'd13: hdr_b = seq_r[15:8];
      5'd14: hdr_b = seq_r[23:16];
      5'd15: hdr_b = seq_r[31:24];
      5'd16: hdr_b = uptime_r[7:0];      // timestamp_ms u64 LE
      5'd17: hdr_b = uptime_r[15:8];
      5'd18: hdr_b = uptime_r[23:16];
      5'd19: hdr_b = uptime_r[31:24];
      5'd20: hdr_b = 8'h00;              // 高 32 位 = 0
      5'd21: hdr_b = 8'h00;
      5'd22: hdr_b = 8'h00;
      5'd23: hdr_b = 8'h00;
      default: hdr_b = 8'h00;
    endcase
  end

  //--------------------------------------------------------------------------
  // 当前载荷字节（组合）
  //--------------------------------------------------------------------------
  logic [7:0] pay_b;

  always_comb begin
    pay_b = 8'h00;
    if (typ_r == `M3TL_T_HEARTBEAT) begin
      // pll_locked, ddr3_calib_done, eth_link_up, cam_init_done, stage,
      // reserved[3], uptime_ms(u32), drop_count(u32)
      case (pay_i)
        16'd0:  pay_b = {7'b0, flags_r[0]};
        16'd1:  pay_b = {7'b0, flags_r[1]};
        16'd2:  pay_b = {7'b0, flags_r[2]};
        16'd3:  pay_b = {7'b0, flags_r[3]};
        16'd4:  pay_b = {5'b0, stage_r};
        16'd5:  pay_b = 8'h00;
        16'd6:  pay_b = 8'h00;
        16'd7:  pay_b = 8'h00;
        16'd8:  pay_b = uptime_r[7:0];
        16'd9:  pay_b = uptime_r[15:8];
        16'd10: pay_b = uptime_r[23:16];
        16'd11: pay_b = uptime_r[31:24];
        16'd12: pay_b = drop_r[7:0];
        16'd13: pay_b = drop_r[15:8];
        16'd14: pay_b = drop_r[23:16];
        16'd15: pay_b = drop_r[31:24];
        default: pay_b = 8'h00;
      endcase
    end else begin
      // frames(u32), last_frame_ms(u32), width(u16), height(u16)
      case (pay_i)
        16'd0:  pay_b = cam_frames_r[7:0];
        16'd1:  pay_b = cam_frames_r[15:8];
        16'd2:  pay_b = cam_frames_r[23:16];
        16'd3:  pay_b = cam_frames_r[31:24];
        16'd4:  pay_b = cam_last_r[7:0];
        16'd5:  pay_b = cam_last_r[15:8];
        16'd6:  pay_b = cam_last_r[23:16];
        16'd7:  pay_b = cam_last_r[31:24];
        16'd8:  pay_b = cam_w_r[7:0];
        16'd9:  pay_b = cam_w_r[15:8];
        16'd10: pay_b = cam_h_r[7:0];
        16'd11: pay_b = cam_h_r[15:8];
        default: pay_b = 8'h00;
      endcase
    end
  end

  //--------------------------------------------------------------------------
  // CRC：逐字节，复用厂商 crc32_d8（crc_result == zlib.crc32）
  //--------------------------------------------------------------------------
  logic        crc_init;
  logic        crc_en;
  logic [7:0]  crc_data;
  wire  [31:0] crc_result;

  assign crc_init = (st == M_HINIT) || (st == M_PINIT);
  assign crc_en   = (st == M_HDR)   || (st == M_PAY);
  assign crc_data = (st == M_HDR) ? hdr_b :
                    (st == M_PAY) ? pay_b : 8'h00;

  // 用发侧那份 crc32_d8_txn（端口名 reset_n，与本模块 rst_n 同为低有效）
  crc32_d8_txn u_crc (
    .clk        (clk125m),
    .reset_n    (rst_n),
    .data       (crc_data),
    .crc_init   (crc_init),
    .crc_en     (crc_en),
    .crc_result (crc_result)
  );

  //--------------------------------------------------------------------------
  // 主状态机
  //--------------------------------------------------------------------------
  logic tx_start_r;

  always_ff @(posedge clk125m or negedge rst_n) begin
    if (!rst_n) begin
      st          <= M_IDLE;
      hdr_i       <= 5'd0;
      pay_i       <= 16'd0;
      idx         <= 16'd0;
      typ_r       <= 8'h00;
      plen_r      <= 16'd0;
      seq_r       <= 32'd0;
      total_r     <= 16'd0;
      seq_hb      <= 32'd0;
      seq_cam     <= 32'd0;
      flags_r     <= 8'h00;
      stage_r     <= 3'd0;
      uptime_r    <= 32'd0;
      drop_r      <= 32'd0;
      cam_frames_r<= 32'd0;
      cam_last_r  <= 32'd0;
      cam_w_r     <= 16'd0;
      cam_h_r     <= 16'd0;
      tx_start_r  <= 1'b0;
      tx_pkt_cnt  <= 32'd0;
      hb_clr      <= 1'b0;
      cam_clr     <= 1'b0;
    end else begin
      tx_start_r <= 1'b0;
      hb_clr     <= 1'b0;
      cam_clr    <= 1'b0;

      case (st)
        //------------------------------------------------------------------
        M_IDLE: begin
          idx    <= 16'd0;
          hdr_i  <= 5'd0;
          pay_i  <= 16'd0;
          if (hb_due) begin
            typ_r  <= `M3TL_T_HEARTBEAT;
            plen_r <= HB_PLEN;
            seq_r  <= seq_hb;
            seq_hb <= seq_hb + 32'd1;
            flags_r<= stat_flags;
            stage_r<= stage;
            uptime_r <= uptime_ms;
            drop_r   <= drop_count;
            hb_clr   <= 1'b1;          // 通过脉冲清零，避免多驱动
            st     <= M_HINIT;
          end else if (cam_due) begin
            typ_r  <= `M3TL_T_CAMERA;
            plen_r <= CAM_PLEN;
            seq_r  <= seq_cam;
            seq_cam<= seq_cam + 32'd1;
            cam_frames_r <= cam_frames;
            cam_last_r   <= cam_last_ms;
            cam_w_r      <= cam_width;
            cam_h_r      <= cam_height;
            cam_clr  <= 1'b1;          // 通过脉冲清零，避免多驱动
            st     <= M_HINIT;
          end
        end

        //------------------------------------------------------------------
        M_HINIT: st <= M_HDR;

        M_HDR: begin
          if (hdr_i == 5'd23) begin
            st <= M_HLATCH;
          end else begin
            hdr_i <= hdr_i + 5'd1;
          end
        end

        M_HLATCH: begin
          pay_i <= 16'd0;
          st    <= M_PINIT;
        end

        //------------------------------------------------------------------
        M_PINIT: st <= M_PAY;

        M_PAY: begin
          if (pay_i == plen_r - 16'd1) begin
            st <= M_PLATCH;
          end else begin
            pay_i <= pay_i + 16'd1;
          end
        end

        M_PLATCH: begin
          total_r <= HDR_LEN + plen_r;
          st      <= M_READY;
        end

        //------------------------------------------------------------------
        M_READY: begin
          tx_start_r <= 1'b1;                     // 单周期脉冲
          idx        <= 16'd0;
          st         <= M_SEND;
        end

        M_SEND: begin
          if (tx_req) begin
            if (idx == total_r - 16'd1) begin
              st         <= M_IDLE;
              tx_pkt_cnt <= tx_pkt_cnt + 32'd1;
            end else begin
              idx <= idx + 16'd1;
            end
          end
        end

        default: st <= M_IDLE;
      endcase
    end
  end

  //--------------------------------------------------------------------------
  // 帧缓冲写口（单独一个"无复位"的时序块，便于综合成 LUTRAM，且不会出现
  // "同时 Set 与 Reset" 的告警）。写入时刻与主状态机当拍状态严格一致：
  //   M_HDR    : 写帧头字节（同时该字节已被送入 crc32_d8）
  //   M_HLATCH : 写 header_crc32（偏移 24..27，小端）
  //   M_PAY    : 写载荷字节（同时该字节已被送入 crc32_d8）
  //   M_PLATCH : 写 payload_crc32（偏移 28..31，小端）
  //--------------------------------------------------------------------------
  // Four byte lanes give one write per RAM bank even for a CRC word.
  // LUTRAM preserves the existing asynchronous byte read: no added cycles.
  localparam integer PACKET_BANK_DEPTH = 128;
  localparam integer PACKET_BANK_AW = $clog2(PACKET_BANK_DEPTH);
  logic [PACKET_BANK_AW-1:0] packet_waddr;
  logic [3:0] packet_we;
  logic [31:0] packet_wdata;
  wire [15:0] packet_byte_addr = HDR_LEN + pay_i;
  wire [7:0] packet_rbyte [0:3];
  always_comb begin
    packet_waddr = '0; packet_we = '0; packet_wdata = '0;
    if (rst_n) begin
      case (st)
        M_HDR: begin
          packet_waddr = hdr_i >> 2;
          packet_we = 4'b0001 << hdr_i[1:0];
          packet_wdata = {4{hdr_b}};
        end
        M_HLATCH: begin
          packet_waddr = 6; packet_we = 4'b1111;
          packet_wdata = crc_result;
        end
        M_PAY: begin
          packet_waddr = packet_byte_addr >> 2;
          packet_we = 4'b0001 << packet_byte_addr[1:0];
          packet_wdata = {4{pay_b}};
        end
        M_PLATCH: begin
          packet_waddr = 7; packet_we = 4'b1111;
          packet_wdata = crc_result;
        end
        default: ;
      endcase
    end
  end
  generate for (genvar lane=0; lane<4; lane=lane+1) begin:g_packet_bank
    (* ram_style="distributed" *) logic [7:0] memory[0:PACKET_BANK_DEPTH-1];
    always_ff @(posedge clk125m) begin
      if (packet_we[lane]) memory[packet_waddr] <= packet_wdata[lane*8+:8];
    end
    assign packet_rbyte[lane] = memory[idx[PACKET_BANK_AW+1:2]];
  end endgenerate

  //--------------------------------------------------------------------------
  // 对外握手
  //--------------------------------------------------------------------------
  assign tx_start   = tx_start_r;
  assign tx_len     = total_r;                       // UDP 载荷长度 = 32 + payload_len
  assign tx_payload = (idx < total_r) ? packet_rbyte[idx[1:0]] : 8'h00;
  assign tx_busy    = (st != M_IDLE);

  //==========================================================================
  // TODO：后续接感知核时扩展
  //
  //  type=3 (TARGETS)：载荷 = 4 字节头 (count:u8, overflow:u8, reserved:u16)
  //                     + count * 16 字节记录
  //                     (id:u8, flags:u8, x_min:i16, x_max:i16, y_min:i16,
  //                      y_max:i16, z_min:i16, z_max:i16, nearest_mm:u16)
  //                     最多 32 条 → 载荷最大 516 字节。
  //                     做法：在 M_IDLE 增加 targets_due 触发与一个目标记录写入
  //                     通道（沿用 frame_buf + pay_i 递增），payload_len 用动态值。
  //
  //  type=5 (GRID)：载荷 = 8 字节头 (rows:u8=55, cols:u8=60, cell_mm:u16=100,
  //                     reserved:u32) + 413 字节位图。
  //                     位图行优先：格子线性下标 n = row*60 + col，
  //                     落在 byte[n>>3] 的 bit(n & 7)（每字节 bit0 起）。
  //                     总载荷 421 字节，帧缓冲需容纳 32+421=453 字节（当前 512 够用）。
  //                     做法：GRID 需要等感知核给出位图，建议增加一个位图写口
  //                     (addr/data/wen) 直接往 frame_buf[32+8+n] 写，写满 413
  //                     字节后再走 M_HINIT/M_HDR（注意 payload_len=421）。
  //==========================================================================

endmodule