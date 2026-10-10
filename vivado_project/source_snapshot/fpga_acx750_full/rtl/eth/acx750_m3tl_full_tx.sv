//============================================================================
// acx750_m3tl_full_tx -- M3TL v1 遥测帧组装与节流发送（扩展版）
//
// 在 acx750_m3tl_tx 的能力之上新增：
//   type=5 GRID          载荷 8 + 413 = 421 字节（UDP 载荷长度 453）
//   type=7 CONFIG_READBACK 载荷 8 字节（UDP 载荷长度 40）
//   type=3 TARGETS       载荷 4 + 16×count 字节（count<=32 -> 最长 516，UDP 548）
// 并保留：
//   type=1 HEARTBEAT     载荷 16 字节
//   type=6 CAMERA_STATUS 载荷 12 字节
//
// 协议权威定义：docs/telemetry_protocol.md（含末尾「类型补充」）
// 帧头、CRC、字节序、sequence 策略与 acx750_m3tl_tx 完全一致（复用同一套
// crc32_d8_txn 用法与逐字节「顺序构建」方式），因此 type=1/6 的输出与旧模块
// 逐字节相同（回归不退化）。
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
// 传给仲裁器的 tx_len 是 UDP 载荷长度 = 32 + payload_len。
//
//--------------------------------------------------------------------------
// 类型与长度
//--------------------------------------------------------------------------
//   type=1  payload_len=16   tx_len=48
//   type=6  payload_len=12   tx_len=44
//   type=5  payload_len=421  tx_len=453
//   type=7  payload_len=8    tx_len=40
//   type=3  payload_len=4+16*count (count<=32)  tx_len=36..548
//
//--------------------------------------------------------------------------
// type=3 目标表（数据来自 acx750_m3tl_targets 的旁路监听结果）
//--------------------------------------------------------------------------
//   tgt_valid 有效时 tgt_payload 保持稳定（4B 头 + 32×16B，共 516 字节），
//   发送器在本帧字节吐完后回一拍 tgt_ack；本模块 IDLE 里优先级为
//   type=7 → type=3 → type=1 → type=6 → type=5。
//   只发"新表"：tgt_valid 由 targets 模块按 SEND_PERIOD_MS 周期产生，本模块另有
//   SEND_PERIOD_MS 兜底节流（两次 type=3 至少间隔该周期），不会空转发旧数据。
//   payload_len = 4 + 16*count；整包 tx_len = 32 + payload_len（count=32 时 548）。
//
//--------------------------------------------------------------------------
// type=5 栅格读出握手（与 acx750_grid_reader 的约定；读出器未就绪，待联调）
//--------------------------------------------------------------------------
//   1) 栅格周期到：本模块在 grid_snapshot_start 上发单周期脉冲，请读出器做一次
//      快照（读出期间数据必须冻结）。
//   2) 读出器完成快照后，在 grid_snapshot_done 上给一拍高（可为一拍脉冲）。
//   3) 紧随 done 之后，读出器连续 413 拍每拍输出一个新字节，grid_byte_valid=1
//      （即 done 后第 1 拍给出 bitmap[0]，第 413 拍给出 bitmap[412]）。
//   4) 本模块在 M_GREAD 状态逐字节取（grid_byte_valid=1 当拍即消费），按行优先
//      顺序写入内部位图缓冲；413 字节取满后再构建帧头并发送。
//   注：接口没有 ready/backpressure，读出器须保证 done 之后字节流背靠背、不重复、
//      不丢失。若真实读出器节流行为不同，需要在这里同步修改（见报告）。
//
//--------------------------------------------------------------------------
// type=7 配置回读
//--------------------------------------------------------------------------
//   收到 cfg_rb_valid 单周期脉冲即锁存一条 (word_index, value)，随后最高优先级
//   立即组包发出（若正忙于发别的帧则记入 1 深度 pending，本帧发完即补发，不丢）。
//   因组包本身需要若干拍，实际发出比 cfg_rb_valid 晚几十拍（125 MHz 下 < 1 us）。
//
//============================================================================
`timescale 1ns/1ps

`include "../acx750_defs.svh"

module acx750_m3tl_full_tx #(
  parameter int unsigned CLK_HZ         = 125_000_000,
  parameter int unsigned HB_PERIOD_MS   = 500,
  parameter int unsigned CAM_PERIOD_MS  = 1000,
  parameter int unsigned GRID_PERIOD_MS = 1000,
  parameter int unsigned SEND_PERIOD_MS = 1000,      // type=3 兜底节流周期
  parameter int unsigned TARGETS_MAX    = 32         // 目标表容量（与 targets 模块一致）
)(
  input  logic        clk125m,
  input  logic        rst_n,

  // --- type=1 心跳 ---
  input  logic [7:0]  stat_flags,
  input  logic [2:0]  stage,
  input  logic [31:0] uptime_ms,
  input  logic [31:0] drop_count,

  // --- type=6 相机 ---
  input  logic [31:0] cam_frames,
  input  logic [31:0] cam_last_ms,
  input  logic [15:0] cam_width,
  input  logic [15:0] cam_height,

  // --- type=5 栅格：从栅格读出器逐字节取 ---
  input  logic [7:0]  grid_byte,
  input  logic        grid_byte_valid,
  output logic        grid_snapshot_start,
  input  logic        grid_snapshot_done,
  input  logic [15:0] grid_rows,
  input  logic [15:0] grid_cols,
  input  logic [15:0] grid_cell_mm,

  // --- type=7 配置回读 ---
  input  logic [31:0] cfg_rb_word_index,
  input  logic [31:0] cfg_rb_value,
  input  logic        cfg_rb_valid,

  // --- type=3 目标表（来自 acx750_m3tl_targets）---
  //   tgt_valid 有效期间 tgt_payload 必须保持稳定，直到本模块回 tgt_ack。
  input  logic [7:0]  tgt_count,                  // 本包目标数（<=32）
  input  logic [7:0]  tgt_overflow,               // 溢出标志（并入 4B 头，见下）
  input  logic [(4+TARGETS_MAX*16)*8-1:0] tgt_payload,  // 4B 头 + 32×16B
  input  logic        tgt_valid,
  output logic        tgt_ack,

  // --- 目的地址（本模块不使用，保留以匹配冻结接口）---
  input  logic [47:0] dst_mac,
  input  logic [31:0] dst_ip,

  // --- 到仲裁器（与既有 acx750_m3tl_tx 的用法一致）---
  output logic        tx_start,
  output logic [15:0] tx_len,
  input  logic        tx_req,
  output logic [7:0]  tx_payload,
  output logic        tx_busy,

  // --- 统计 ---
  output logic [31:0] tx_pkt_cnt,
  output logic [31:0] grid_tx_cnt
);

  // 载荷长度常量
  localparam logic [15:0] HDR_LEN    = 16'd32;
  localparam logic [15:0] HB_PLEN    = 16'd16;
  localparam logic [15:0] CAM_PLEN   = 16'd12;
  localparam logic [15:0] GRID_PLEN  = 16'd421;   // 8 头 + 413 位图
  localparam logic [15:0] CFG_PLEN   = 16'd8;
  localparam logic [15:0] GRID_BITMAP= 16'd413;
  localparam logic [15:0] TGT_HEAD   = 16'd4;     // type=3 载荷 4B 头
  localparam logic [7:0]  TGT_MAX_B  = TARGETS_MAX;   // 目标数上限（8bit 视图）

  localparam logic [7:0]  T_CFG_RB   = 8'd7;      // 协议未在 defs 中定义，这里就地定义

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
  logic [31:0] grid_ms_cnt;
  logic [31:0] tgt_ms_cnt;
  // 计数器只能有一个驱动源——清零必须通过脉冲回灌，避免 multi-driven net。
  logic        hb_clr, cam_clr, grid_clr, tgt_clr;

  always_ff @(posedge clk125m or negedge rst_n) begin
    if (!rst_n) begin
      hb_ms_cnt   <= 32'd0;
      cam_ms_cnt  <= 32'd0;
      grid_ms_cnt <= 32'd0;
      tgt_ms_cnt  <= 32'd0;
    end else if (hb_clr) begin
      hb_ms_cnt   <= 32'd0;
    end else if (cam_clr) begin
      cam_ms_cnt  <= 32'd0;
    end else if (grid_clr) begin
      grid_ms_cnt <= 32'd0;
    end else if (tgt_clr) begin
      tgt_ms_cnt  <= 32'd0;
    end else if (tick_ms) begin
      if (hb_ms_cnt   < HB_PERIOD_MS)   hb_ms_cnt   <= hb_ms_cnt   + 32'd1;
      if (cam_ms_cnt  < CAM_PERIOD_MS)  cam_ms_cnt  <= cam_ms_cnt  + 32'd1;
      if (grid_ms_cnt < GRID_PERIOD_MS) grid_ms_cnt <= grid_ms_cnt + 32'd1;
      if (tgt_ms_cnt  < SEND_PERIOD_MS) tgt_ms_cnt  <= tgt_ms_cnt  + 32'd1;
    end
  end

  wire hb_due   = (hb_ms_cnt   >= HB_PERIOD_MS);
  wire cam_due  = (cam_ms_cnt  >= CAM_PERIOD_MS);
  wire grid_due = (grid_ms_cnt >= GRID_PERIOD_MS);
  wire tgt_due  = (tgt_ms_cnt  >= SEND_PERIOD_MS);

  //==========================================================================
  // 2. type=7 请求锁存（1 深度 pending，不丢单次请求）
  //==========================================================================
  logic        cfg_pend;
  logic [31:0] cfg_wi_l;
  logic [31:0] cfg_val_l;

  always_ff @(posedge clk125m or negedge rst_n) begin
    if (!rst_n) begin
      cfg_wi_l  <= 32'd0;
      cfg_val_l <= 32'd0;
    end else if (cfg_rb_valid) begin
      cfg_wi_l  <= cfg_rb_word_index;
      cfg_val_l <= cfg_rb_value;
    end
  end

  //==========================================================================
  // 3. 帧缓冲与构建状态机
  //==========================================================================
  typedef enum logic [3:0] {
    M_IDLE   = 4'd0,
    M_GSTART = 4'd1,   // 请读出器快照（发 grid_snapshot_start 脉冲）
    M_GWAIT  = 4'd2,   // 等 grid_snapshot_done
    M_GREAD  = 4'd3,   // 逐字节读 413 字节位图
    M_HINIT  = 4'd4,   // 帧头 CRC 复位一拍
    M_HDR    = 4'd5,   // 写帧头 0..23，同时喂 CRC
    M_HLATCH = 4'd6,   // 写 header_crc32
    M_PINIT  = 4'd7,   // 载荷 CRC 复位一拍
    M_PAY    = 4'd8,   // 写载荷，同时喂 CRC
    M_PLATCH = 4'd9,   // 写 payload_crc32
    M_READY  = 4'd10,  // 向仲裁器发 tx_start
    M_SEND   = 4'd11   // 等 tx_req 逐字节吐出
  } mstate_e;

  mstate_e     st;
  logic [7:0]  frame_buf [0:559];  // 32 字节头 + 载荷（最大 516 -> 整包 548）
  logic [7:0]  grid_buf  [0:412];  // 栅格位图缓冲（413 字节）

  logic [7:0]  typ_r;
  logic [15:0] plen_r;
  logic [31:0] seq_r;
  logic [15:0] total_r;
  logic [31:0] seq_hb, seq_cam, seq_grid, seq_cfg, seq_tgt;

  // type=3：本次取表锁存 + 握手
  logic [7:0]  tgt_n_r;      // 已钳到 <=32 的目标数（决定 payload_len）
  logic [7:0]  tgt_ovf_r;    // 溢出字节
  logic        tgt_seen;     // 本次 tgt_valid 断言已被消费（防止同一断言重复发）
  logic [7:0]  tgt_ack_r;    // 回给 targets 的取走脉冲
  wire  [7:0]  tgt_n_in = (tgt_count > TGT_MAX_B) ? TGT_MAX_B : tgt_count;

  // 构建期间锁存的状态快照
  logic [7:0]  flags_r;
  logic [2:0]  stage_r;
  logic [31:0] uptime_r;
  logic [31:0] drop_r;
  logic [31:0] cam_frames_r;
  logic [31:0] cam_last_r;
  logic [15:0] cam_w_r;
  logic [15:0] cam_h_r;
  logic [15:0] rows_r, cols_r, cellmm_r;
  logic [31:0] cfg_wi_r, cfg_val_r;

  logic [4:0]  hdr_i;         // 0..23
  logic [15:0] pay_i;         // 0..plen_r-1
  logic [15:0] idx;           // 发送下标
  logic [8:0]  grid_rd_cnt;   // 0..412

  logic        tx_start_r;
  logic        grid_snap_start_r;

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
  logic [7:0]  pay_b;
  wire  [8:0]  gbm_idx = pay_i[8:0] - 9'd8;   // 位图在 grid_buf 中的下标

  always_comb begin
    pay_b = 8'h00;
    case (typ_r)
      `M3TL_T_HEARTBEAT: begin
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
      end

      `M3TL_T_CAMERA: begin
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

      `M3TL_T_GRID: begin
        // rows:u8, cols:u8, cell_mm:u16, reserved:u32, bitmap:u8[413]
        case (pay_i)
          16'd0: pay_b = rows_r[7:0];
          16'd1: pay_b = cols_r[7:0];
          16'd2: pay_b = cellmm_r[7:0];
          16'd3: pay_b = cellmm_r[15:8];
          16'd4: pay_b = 8'h00;
          16'd5: pay_b = 8'h00;
          16'd6: pay_b = 8'h00;
          16'd7: pay_b = 8'h00;
          default: pay_b = grid_buf[gbm_idx];
        endcase
      end

      T_CFG_RB: begin
        // word_index:u32 LE, value:u32 LE
        case (pay_i)
          16'd0: pay_b = cfg_wi_r[7:0];
          16'd1: pay_b = cfg_wi_r[15:8];
          16'd2: pay_b = cfg_wi_r[23:16];
          16'd3: pay_b = cfg_wi_r[31:24];
          16'd4: pay_b = cfg_val_r[7:0];
          16'd5: pay_b = cfg_val_r[15:8];
          16'd6: pay_b = cfg_val_r[23:16];
          16'd7: pay_b = cfg_val_r[31:24];
          default: pay_b = 8'h00;
        endcase
      end

      `M3TL_T_TARGETS: begin
        // 4B 头（count/overflow/保留）由本模块用锁存值生成；
        // 记录字节直接从 targets 的 tgt_payload 取（该表在 tgt_ack 前保持稳定）。
        case (pay_i)
          16'd0:   pay_b = tgt_n_r;
          16'd1:   pay_b = tgt_ovf_r;
          16'd2:   pay_b = 8'h00;
          16'd3:   pay_b = 8'h00;
          default: pay_b = tgt_payload[pay_i[9:0]*8 +: 8];
        endcase
      end

      default: pay_b = 8'h00;
    endcase
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
  always_ff @(posedge clk125m or negedge rst_n) begin
    if (!rst_n) begin
      st              <= M_IDLE;
      hdr_i           <= 5'd0;
      pay_i           <= 16'd0;
      idx             <= 16'd0;
      typ_r           <= 8'h00;
      plen_r          <= 16'd0;
      seq_r           <= 32'd0;
      total_r         <= 16'd0;
      seq_hb          <= 32'd0;
      seq_cam         <= 32'd0;
      seq_grid        <= 32'd0;
      seq_cfg         <= 32'd0;
      seq_tgt         <= 32'd0;
      tgt_n_r         <= 8'd0;
      tgt_ovf_r       <= 8'd0;
      tgt_seen        <= 1'b0;
      tgt_ack_r       <= 1'b0;
      flags_r         <= 8'h00;
      stage_r         <= 3'd0;
      uptime_r        <= 32'd0;
      drop_r          <= 32'd0;
      cam_frames_r    <= 32'd0;
      cam_last_r      <= 32'd0;
      cam_w_r         <= 16'd0;
      cam_h_r         <= 16'd0;
      rows_r          <= 16'd0;
      cols_r          <= 16'd0;
      cellmm_r        <= 16'd0;
      cfg_wi_r        <= 32'd0;
      cfg_val_r       <= 32'd0;
      grid_rd_cnt     <= 9'd0;
      tx_start_r      <= 1'b0;
      grid_snap_start_r <= 1'b0;
      tx_pkt_cnt      <= 32'd0;
      grid_tx_cnt     <= 32'd0;
      hb_clr          <= 1'b0;
      cam_clr         <= 1'b0;
      grid_clr        <= 1'b0;
      cfg_pend        <= 1'b0;
    end else begin
      tx_start_r        <= 1'b0;
      grid_snap_start_r <= 1'b0;
      hb_clr            <= 1'b0;
      cam_clr           <= 1'b0;
      grid_clr          <= 1'b0;
      tgt_clr           <= 1'b0;
      tgt_ack_r         <= 1'b0;

      // type=3：tgt_valid 由 targets 保持到 tgt_ack，收到低电平即解除"已消费"
      if (!tgt_valid) tgt_seen <= 1'b0;

      // type=7 请求寄存：收到即置位；被 IDLE 消费后清除。
      // cfg_rb_valid 优先，保证"同一拍既消费旧请求又收到新请求"时不丢新的。
      if (cfg_rb_valid) begin
        cfg_pend <= 1'b1;
      end else if ((st == M_IDLE) && cfg_pend) begin
        cfg_pend <= 1'b0;
      end

      case (st)
        //------------------------------------------------------------------
        M_IDLE: begin
          idx   <= 16'd0;
          hdr_i <= 5'd0;
          pay_i <= 16'd0;
          if (cfg_pend) begin
            // 最高优先级：配置回读立即组包
            typ_r    <= T_CFG_RB;
            plen_r   <= CFG_PLEN;
            seq_r    <= seq_cfg;
            seq_cfg  <= seq_cfg + 32'd1;
            cfg_wi_r <= cfg_wi_l;
            cfg_val_r<= cfg_val_l;
            uptime_r <= uptime_ms;
            st       <= M_HINIT;
          end else if (tgt_valid && !tgt_seen && tgt_due) begin
            // 有新表：取表并组 type=3。tgt_payload 在 tgt_ack 前保持稳定，
            // 故本帧在 M_PAY 里直接逐字节读 tgt_payload，无需再存一份。
            typ_r    <= `M3TL_T_TARGETS;
            plen_r   <= TGT_HEAD + {8'd0, tgt_n_in} * 16'd16;   // 4 + 16*count
            seq_r    <= seq_tgt;
            seq_tgt  <= seq_tgt + 32'd1;
            tgt_n_r  <= tgt_n_in;
            tgt_ovf_r<= tgt_overflow;
            uptime_r <= uptime_ms;
            tgt_clr  <= 1'b1;
            tgt_seen <= 1'b1;
            st       <= M_HINIT;
          end else if (hb_due) begin
            typ_r   <= `M3TL_T_HEARTBEAT;
            plen_r  <= HB_PLEN;
            seq_r   <= seq_hb;
            seq_hb  <= seq_hb + 32'd1;
            flags_r <= stat_flags;
            stage_r <= stage;
            uptime_r<= uptime_ms;
            drop_r  <= drop_count;
            hb_clr  <= 1'b1;
            st      <= M_HINIT;
          end else if (cam_due) begin
            typ_r       <= `M3TL_T_CAMERA;
            plen_r      <= CAM_PLEN;
            seq_r       <= seq_cam;
            seq_cam     <= seq_cam + 32'd1;
            cam_frames_r<= cam_frames;
            cam_last_r  <= cam_last_ms;
            cam_w_r     <= cam_width;
            cam_h_r     <= cam_height;
            uptime_r    <= uptime_ms;
            cam_clr     <= 1'b1;
            st          <= M_HINIT;
          end else if (grid_due) begin
            grid_clr <= 1'b1;         // 已决定发栅格，重新计时
            st       <= M_GSTART;
          end
        end

        //------------------------------------------------------------------
        // type=5：请读出器快照 → 等 done → 逐字节读位图
        //------------------------------------------------------------------
        M_GSTART: begin
          grid_snap_start_r <= 1'b1;   // 单周期脉冲（下一拍输出）
          grid_rd_cnt       <= 9'd0;
          st                <= M_GWAIT;
        end

        M_GWAIT: begin
          if (grid_snapshot_done) begin
            typ_r    <= `M3TL_T_GRID;
            plen_r   <= GRID_PLEN;
            seq_r    <= seq_grid;
            seq_grid <= seq_grid + 32'd1;
            rows_r   <= grid_rows;
            cols_r   <= grid_cols;
            cellmm_r <= grid_cell_mm;
            uptime_r <= uptime_ms;
            st       <= M_GREAD;
          end
        end

        M_GREAD: begin
          if (grid_byte_valid) begin
            if (grid_rd_cnt == GRID_BITMAP[8:0] - 9'd1) begin
              st <= M_HINIT;
            end else begin
              grid_rd_cnt <= grid_rd_cnt + 9'd1;
            end
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
          tx_start_r <= 1'b1;
          idx        <= 16'd0;
          st         <= M_SEND;
        end

        M_SEND: begin
          if (tx_req) begin
            if (idx == total_r - 16'd1) begin
              st         <= M_IDLE;
              tx_pkt_cnt <= tx_pkt_cnt + 32'd1;
              if (typ_r == `M3TL_T_GRID)    grid_tx_cnt <= grid_tx_cnt + 32'd1;
              if (typ_r == `M3TL_T_TARGETS) tgt_ack_r    <= 1'b1;
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
  // 帧缓冲 / 位图缓冲写口（无复位，便于综合成 LUTRAM）
  //--------------------------------------------------------------------------
  always_ff @(posedge clk125m) begin
    case (st)
      M_HDR: begin
        frame_buf[hdr_i] <= hdr_b;
      end
      M_HLATCH: begin
        frame_buf[16'd24] <= crc_result[7:0];
        frame_buf[16'd25] <= crc_result[15:8];
        frame_buf[16'd26] <= crc_result[23:16];
        frame_buf[16'd27] <= crc_result[31:24];
      end
      M_PAY: begin
        frame_buf[HDR_LEN + pay_i] <= pay_b;
      end
      M_PLATCH: begin
        frame_buf[16'd28] <= crc_result[7:0];
        frame_buf[16'd29] <= crc_result[15:8];
        frame_buf[16'd30] <= crc_result[23:16];
        frame_buf[16'd31] <= crc_result[31:24];
      end
      M_GREAD: begin
        if (grid_byte_valid) grid_buf[grid_rd_cnt] <= grid_byte;
      end
      default: ;
    endcase
  end

  //--------------------------------------------------------------------------
  // 对外握手
  //--------------------------------------------------------------------------
  assign tx_start           = tx_start_r;
  assign tx_len             = total_r;                     // UDP 载荷长度 = 32 + payload_len
  assign tx_payload         = (idx < total_r) ? frame_buf[idx] : 8'h00;
  assign tx_busy            = (st != M_IDLE);
  assign grid_snapshot_start= grid_snap_start_r;
  assign tgt_ack            = tgt_ack_r;

  // 说明：dst_mac / dst_ip 由仲裁器/顶层使用，本模块不参与组帧，保持端口以
  // 匹配冻结接口（未使用属正常）。

endmodule