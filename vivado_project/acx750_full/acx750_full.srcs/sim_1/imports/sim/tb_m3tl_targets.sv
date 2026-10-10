//============================================================================
// tb_m3tl_targets -- acx750_m3tl_targets + acx750_m3tl_full_tx(type=3) 自检
//
// 覆盖：
//   1) type=3 目标表：造 2~3 个人造目标（非对称数值），按"acknowledged 12 字 ->
//      16 字节"映射塞进 snapshot_object 走一次走查，逐字节核对记录；
//   2) 整包 548 字节（count=32）：type / payload_len / count / 两个 CRC；
//   3) 边界：count=32 / count=1 / count=0；
//   4) 轻量回归：同台例化 full_tx，核对一次 type=1 心跳整帧（CRC 与既有
//      tb_m3tl_full 常量一致），证明 type=1/5/6/7 未退化（type=5/6/7 的完整
//      81 项回归由未改动的 sim/tb_m3tl_full.sv 另行跑，见报告）。
//
// CRC 期望值由 Python zlib.crc32 现算（见文件末注释与 gen.py），与 RTL 实测对比。
// 末尾打印 "PASS m3tl_targets" 或 "FAIL m3tl_targets"。
//============================================================================
`timescale 1ns/1ps

module tb_m3tl_targets;

  localparam int CLK_HZ  = 1000;       // TICK_DIV=1 -> 每拍 1 "ms"
  localparam int HB_P    = 200;
  localparam int CAM_P   = 100000;     // 不触发
  localparam int GRID_P  = 100000;     // 不触发（避免等栅格读出器）
  localparam int TGT_P   = 4;          // type=3 周期（targets 与 tx 同值）
  localparam logic [31:0] UPTIME = 32'd123456;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  // --- 走查激励（模拟 perception_regs 的走查）---
  logic         w_busy;
  logic [4:0]   w_idx;
  logic [383:0] w_obj;
  logic [1023:0] w_meta;
  logic         w_start;

  // --- targets <-> tx ---
  logic [7:0]   tgt_count, tgt_overflow;
  logic [4127:0] tgt_payload;      // 4B 头 + 32*16B = 516 字节
  logic         tgt_valid, tgt_ack;
  logic [31:0]  tgt_rx_cnt;

  // --- tx 其它端口 ---
  logic [7:0]  grid_byte;
  logic        grid_byte_valid, grid_snapshot_start, grid_snapshot_done;
  logic [15:0] grid_rows, grid_cols, grid_cell_mm;
  logic [31:0] cfg_rb_word_index, cfg_rb_value;
  logic        cfg_rb_valid;
  logic [47:0] dst_mac;
  logic [31:0] dst_ip;
  logic        tx_start;
  logic [15:0] tx_len;
  logic        tx_req;
  logic [7:0]  tx_payload;
  logic        tx_busy;
  logic [31:0] tx_pkt_cnt, grid_tx_cnt;

  assign tx_req = 1'b1;   // 仲裁器恒 ready：帧 READY 后连续吐出

  acx750_m3tl_targets #(
    .TARGETS_MAX   (32),
    .SEND_PERIOD_MS(TGT_P),
    .CLK_HZ        (CLK_HZ)
  ) dut_t (
    .clk            (clk),
    .rst_n          (rst_n),
    .snapshot_start (w_start),
    .snapshot_busy  (w_busy),
    .snapshot_index (w_idx),
    .snapshot_object(w_obj),
    .metadata       (w_meta),
    .tgt_count      (tgt_count),
    .tgt_overflow   (tgt_overflow),
    .tgt_payload    (tgt_payload),
    .tgt_valid      (tgt_valid),
    .tgt_ack        (tgt_ack),
    .tgt_rx_cnt     (tgt_rx_cnt)
  );

  acx750_m3tl_full_tx #(
    .CLK_HZ        (CLK_HZ),
    .HB_PERIOD_MS  (HB_P),
    .CAM_PERIOD_MS (CAM_P),
    .GRID_PERIOD_MS(GRID_P),
    .SEND_PERIOD_MS(TGT_P),
    .TARGETS_MAX   (32)
  ) dut_x (
    .clk125m(clk), .rst_n(rst_n),
    .stat_flags(8'h0B), .stage(3'd5), .uptime_ms(UPTIME), .drop_count(32'h00000042),
    .cam_frames(32'd0), .cam_last_ms(32'd0), .cam_width(16'd0), .cam_height(16'd0),
    .grid_byte(grid_byte), .grid_byte_valid(grid_byte_valid),
    .grid_snapshot_start(grid_snapshot_start), .grid_snapshot_done(grid_snapshot_done),
    .grid_rows(grid_rows), .grid_cols(grid_cols), .grid_cell_mm(grid_cell_mm),
    .cfg_rb_word_index(cfg_rb_word_index), .cfg_rb_value(cfg_rb_value),
    .cfg_rb_valid(cfg_rb_valid),
    .tgt_count(tgt_count), .tgt_overflow(tgt_overflow), .tgt_payload(tgt_payload),
    .tgt_valid(tgt_valid), .tgt_ack(tgt_ack),
    .dst_mac(dst_mac), .dst_ip(dst_ip),
    .tx_start(tx_start), .tx_len(tx_len), .tx_req(tx_req),
    .tx_payload(tx_payload), .tx_busy(tx_busy),
    .tx_pkt_cnt(tx_pkt_cnt), .grid_tx_cnt(grid_tx_cnt)
  );

  //==========================================================================
  // 人造目标：非对称数值（避免对称掩盖字段错位）。
  //   记录字段按协议顺序由 object_t 字段映射而来（见 docs/m3tl_targets_750.md）：
  //     x_min=x0, x_max=x1, y_min=y0, y_max=y1, z_min=z0, z_max=z1,
  //     nearest=floor(sqrt(d2))
  //   object_t 12 个字（[383:0]）：
  //     [383:368]cells [367:352]points [351:320]x0 [319:288]y0 [287:256]z0
  //     [255:224]x1 [223:192]y1 [191:160]z1 [159:96]d2 [95:64]cx [63:32]cy [31:0]cz
  //==========================================================================
  function automatic logic [383:0] mk_obj(input int i);
    logic signed [31:0] x0, x1, y0, y1, z0, z1;
    logic [31:0] near;
    logic [63:0] d2;
    begin
      x0 = 100*i - 1234;   x1 = 100*i + 567;
      y0 = 50*i  - 2000;   y1 = 50*i  + 30;
      z0 = 10*i  - 500;    z1 = 10*i  + 40;
      near = 1000 + i;
      d2   = near * near;
      mk_obj = {16'd0, 16'd0, x0, y0, z0, x1, y1, z1, d2, 32'd0, 32'd0, 32'd0};
    end
  endfunction

  // 走一次"完整走查"：snapshot_busy 拉高 32 拍，index=0..31，每拍给一个对象
  task automatic do_walk(input int cnt);
    begin
      w_meta = 1024'd0;
      w_meta[69:64] = cnt[5:0];
      for (int k = 0; k < 32; k++) begin
        @(negedge clk);
        w_busy = 1'b1;
        w_idx  = k[4:0];
        w_obj  = mk_obj(k);
      end
      @(negedge clk);
      w_busy = 1'b0;
      w_idx  = 5'd0;
      w_obj  = 384'd0;
    end
  endtask

  //==========================================================================
  // 帧抓取（与 tb_m3tl_full 同法，缓冲加大到 560 支持整包 548）
  //==========================================================================
  logic [7:0]  frm [0:559];
  logic [15:0] cap_len;
  int          cap_i;
  logic        cap_busy, cap_done;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cap_busy <= 1'b0; cap_done <= 1'b0; cap_i <= 0; cap_len <= 16'd0;
    end else begin
      cap_done <= 1'b0;
      if (tx_start) begin
        cap_len      <= tx_len;
        frm[0]       <= tx_payload;   // tx_start 当拍 idx=0 -> frame_buf[0]
        cap_i        <= 1;
        if (tx_len <= 16'd1) begin cap_busy <= 1'b0; cap_done <= 1'b1; end
        else                      cap_busy <= 1'b1;
      end else if (cap_busy) begin
        frm[cap_i] <= tx_payload;
        if (cap_i == int'(cap_len) - 1) begin cap_busy <= 1'b0; cap_done <= 1'b1; end
        else                                  cap_i    <= cap_i + 1;
      end
    end
  end

  //==========================================================================
  // 按 type 分派保存（只留前 3 个 type=3 与第 1 个 type=1）
  //==========================================================================
  logic [7:0]  f_t3 [0:2][0:559];
  logic [15:0] L_t3 [0:2];
  logic [7:0]  f_hb [0:559];
  logic [15:0] L_hb;
  int          t3_n, hb_n;
  logic        t3_evt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      t3_n <= 0; hb_n <= 0; t3_evt <= 1'b0;
    end else begin
      t3_evt <= 1'b0;
      if (cap_done) begin
        if (frm[5] == 8'd3) begin
          if (t3_n < 3) begin
            for (int k = 0; k < 560; k++) f_t3[t3_n][k] <= frm[k];
            L_t3[t3_n] <= cap_len;
          end
          t3_n  <= t3_n + 1;
          t3_evt<= 1'b1;
          $display("[cap] t=%0t type=3 tx_len=%0d count=%0d", $time, cap_len, frm[32]);
        end else if (frm[5] == 8'd1) begin
          if (hb_n == 0) begin
            for (int k = 0; k < 560; k++) f_hb[k] <= frm[k];
            L_hb <= cap_len;
          end
          hb_n <= hb_n + 1;
        end
      end
    end
  end

  //==========================================================================
  // 检查工具
  //==========================================================================
  int checks, fails;

  function automatic logic [31:0] le32(input logic [7:0] a [0:559], input int off);
    le32 = {a[off+3], a[off+2], a[off+1], a[off]};
  endfunction

  task automatic chk8(input string tag, input logic [7:0] got, input logic [7:0] exp);
    begin
      checks++;
      if (got !== exp) begin fails++; $display("  [FAIL] %-22s got=%02x exp=%02x", tag, got, exp); end
      else                  $display("  [OK]   %-22s = %02x", tag, got);
    end
  endtask

  task automatic chk32(input string tag, input logic [31:0] got, input logic [31:0] exp);
    begin
      checks++;
      if (got !== exp) begin fails++; $display("  [FAIL] %-22s got=%08x exp=%08x", tag, got, exp); end
      else                  $display("  [OK]   %-22s = %08x", tag, got);
    end
  endtask

  // 逐字节核对一条 16 字节记录（exp 低字节=记录字节 0）
  task automatic chk_rec(input string tag, input logic [7:0] a [0:559],
                         input int off, input logic [127:0] exp);
    logic ok;
    begin
      ok = 1'b1;
      checks += 16;
      for (int k = 0; k < 16; k++)
        if (a[off+k] !== exp[k*8 +: 8]) begin ok = 1'b0; fails++; end
      if (ok) $display("  [OK]   %-22s rec@%0d = %032x", tag, off, exp);
      else    $display("  [FAIL] %-22s rec@%0d got=%032x exp=%032x", tag, off,
                       {a[off+15],a[off+14],a[off+13],a[off+12],a[off+11],a[off+10],a[off+9],a[off+8],
                        a[off+7],a[off+6],a[off+5],a[off+4],a[off+3],a[off+2],a[off+1],a[off+0]}, exp);
    end
  endtask

  task automatic chk_hdr(input string tag, input logic [7:0] a [0:559], input logic [7:0] t,
                         input logic [31:0] plen, input logic [31:0] seq);
    begin
      chk8({tag, ".magic0"}, a[0], 8'h4D);
      chk8({tag, ".magic3"}, a[3], 8'h4C);
      chk8({tag, ".version"}, a[4], 8'h01);
      chk8({tag, ".type"},    a[5], t);
      chk8({tag, ".flags_lo"}, a[6], 8'h00);
      chk8({tag, ".flags_hi"}, a[7], 8'h00);
      chk32({tag, ".payload_len"}, le32(a, 8),  plen);
      chk32({tag, ".sequence"},    le32(a, 12), seq);
      chk32({tag, ".timestamp_lo"}, le32(a, 16), UPTIME);
      chk32({tag, ".timestamp_hi"}, le32(a, 20), 32'd0);
    end
  endtask

  // Python zlib.crc32 现算的期望值
  localparam logic [31:0] EXP_T3A_HDR = 32'hfacb188f, EXP_T3A_PAY = 32'h75e24d98;
  localparam logic [31:0] EXP_T3B_HDR = 32'h2fcfdbef, EXP_T3B_PAY = 32'h6fc54c82;
  localparam logic [31:0] EXP_T3C_HDR = 32'hbe763781, EXP_T3C_PAY = 32'h2144df1c;
  localparam logic [31:0] EXP_HB_HDR  = 32'h14efddf6, EXP_HB_PAY  = 32'hf9fe9979;

  // 记录期望（小端 128bit：低字节 = 记录字节 0）
  localparam logic [127:0] EXP_REC0  = 128'h03e80028fe0c001ef8300237fb2e0000;
  localparam logic [127:0] EXP_REC1  = 128'h03e90032fe160050f862029bfb920001;
  localparam logic [127:0] EXP_REC31 = 128'h0407015eff42062cfe3e0e53074a001f;

  //==========================================================================
  // 激励
  //==========================================================================
  initial begin
    w_busy = 1'b0; w_idx = 5'd0; w_obj = 384'd0; w_meta = 1024'd0; w_start = 1'b0;
    grid_byte = 8'h00; grid_byte_valid = 1'b0; grid_snapshot_done = 1'b0;
    grid_rows = 16'd55; grid_cols = 16'd60; grid_cell_mm = 16'd100;
    cfg_rb_word_index = 32'd0; cfg_rb_value = 32'd0; cfg_rb_valid = 1'b0;
    dst_mac = 48'h00_0a_35_01_fe_c0; dst_ip = 32'hc0_a8_01_0a;

    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    // ---- 走查 1：count=32 ----
    do_walk(32);
    wait (t3_n >= 1);
    repeat (10) @(posedge clk);

    // ---- 走查 2：count=1（等 targets 回到 idle）----
    wait (!tgt_valid);
    repeat (10) @(posedge clk);
    do_walk(1);
    wait (t3_n >= 2);
    repeat (10) @(posedge clk);

    // ---- 走查 3：count=0 ----
    wait (!tgt_valid);
    repeat (10) @(posedge clk);
    do_walk(0);
    wait (t3_n >= 3);

    wait (hb_n >= 1);
    repeat (20) @(posedge clk);

    run_checks();
    if (fails == 0) $display("\nPASS m3tl_targets (%0d checks)", checks);
    else            $display("\nFAIL m3tl_targets (%0d/%0d failed)", fails, checks);
    $finish;
  end

  // 看门狗
  initial begin
    repeat (300000) @(posedge clk);
    $display("\nFAIL m3tl_targets (timeout: t3_n=%0d hb_n=%0d tgt_rx_cnt=%0d)",
             t3_n, hb_n, tgt_rx_cnt);
    $finish;
  end

  //==========================================================================
  // 检查主体
  //==========================================================================
  task automatic run_checks;
    begin
      checks = 0; fails = 0;
      $display("=== tx_pkt_cnt=%0d t3_n=%0d hb_n=%0d tgt_rx_cnt=%0d ===",
               tx_pkt_cnt, t3_n, hb_n, tgt_rx_cnt);

      //------------------------------------------------------- type=3 count=32
      $display("--- type=3 帧A（count=32，整包 548）---");
      chk32("T3A tx_len", L_t3[0], 16'd548);
      chk_hdr("T3A", f_t3[0], 8'd3, 16'd516, 32'd0);
      chk32("T3A header_crc",  le32(f_t3[0], 24), EXP_T3A_HDR);
      chk32("T3A payload_crc", le32(f_t3[0], 28), EXP_T3A_PAY);
      chk8 ("T3A p.count",     f_t3[0][32], 8'd32);
      chk8 ("T3A p.overflow",  f_t3[0][33], 8'd1);
      chk8 ("T3A p.reserved0", f_t3[0][34], 8'h00);
      chk8 ("T3A p.reserved1", f_t3[0][35], 8'h00);
      chk_rec("T3A rec0 ", f_t3[0], 36,  EXP_REC0);
      chk_rec("T3A rec1 ", f_t3[0], 52,  EXP_REC1);
      chk_rec("T3A rec31", f_t3[0], 532, EXP_REC31);

      //-------------------------------------------------------- type=3 count=1
      $display("--- type=3 帧B（count=1，整包 52）---");
      chk32("T3B tx_len", L_t3[1], 16'd52);
      chk_hdr("T3B", f_t3[1], 8'd3, 16'd20, 32'd1);
      chk32("T3B header_crc",  le32(f_t3[1], 24), EXP_T3B_HDR);
      chk32("T3B payload_crc", le32(f_t3[1], 28), EXP_T3B_PAY);
      chk8 ("T3B p.count",     f_t3[1][32], 8'd1);
      chk8 ("T3B p.overflow",  f_t3[1][33], 8'd0);
      chk_rec("T3B rec0 ", f_t3[1], 36, EXP_REC0);

      //-------------------------------------------------------- type=3 count=0
      $display("--- type=3 帧C（count=0，整包 36）---");
      chk32("T3C tx_len", L_t3[2], 16'd36);
      chk_hdr("T3C", f_t3[2], 8'd3, 16'd4, 32'd2);
      chk32("T3C header_crc",  le32(f_t3[2], 24), EXP_T3C_HDR);
      chk32("T3C payload_crc", le32(f_t3[2], 28), EXP_T3C_PAY);
      chk8 ("T3C p.count",     f_t3[2][32], 8'd0);
      chk8 ("T3C p.overflow",  f_t3[2][33], 8'd0);

      //---------------------------------------------------------- 回归 type=1
      $display("--- type=1 心跳（回归，整帧 48）---");
      chk32("HB tx_len", L_hb, 16'd48);
      chk_hdr("HB", f_hb, 8'd1, 16'd16, 32'd0);
      chk32("HB header_crc",  le32(f_hb, 24), EXP_HB_HDR);
      chk32("HB payload_crc", le32(f_hb, 28), EXP_HB_PAY);

      //---------------------------------------------------------- 计数
      chk32("tgt_rx_cnt", tgt_rx_cnt, 32'd3);
    end
  endtask

endmodule

//----------------------------------------------------------------------------
// Python zlib.crc32 期望值（gen.py，UPTIME=123456）：
//   type=3 count=32 seq=0 payload_len=516 tx_len=548 header_crc=0xfacb188f payload_crc=0x75e24d98
//   type=3 count=1  seq=1 payload_len=20  tx_len=52  header_crc=0x2fcfdbef payload_crc=0x6fc54c82
//   type=3 count=0  seq=2 payload_len=4   tx_len=36  header_crc=0xbe763781 payload_crc=0x2144df1c
//   type=1 seq=0 payload_len=16 tx_len=48 header_crc=0x14efddf6 payload_crc=0xf9fe9979
// 记录期望（16B，小端）：
//   rec0  = 00 00 2e fb 37 02 30 f8 1e 00 0c fe 28 00 e8 03
//   rec1  = 01 00 92 fb 9b 02 62 f8 50 00 16 fe 32 00 e9 03
//   rec31 = 1f 00 4a 07 53 0e 3e fe 2c 06 42 ff 5e 01 07 04
//----------------------------------------------------------------------------