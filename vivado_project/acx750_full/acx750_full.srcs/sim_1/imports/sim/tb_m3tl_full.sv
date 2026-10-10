//============================================================================
// tb_m3tl_full -- acx750_m3tl_full_tx 自检测试台
//
// 覆盖：
//   1) type=1/6 回归：与既有 acx750_m3tl_tx 的载荷布局/CRC 完全一致
//   2) type=7：发一次 cfg_rb_valid，核对 40 字节整帧
//   3) type=5：读出器桩给"只置 2 格"的 413 字节位图，核对 453 字节整帧
//   4) 序号独立性：2 个 type=1 与 2 个 type=5 的 sequence 各自独立递增
//
// CRC 期望值由 Python zlib.crc32 现算（见文件末注释），与 RTL 实测逐字节对比。
// 末尾打印 "PASS m3tl_full" 或 "FAIL m3tl_full"。
//
// 说明：本测试台自带"栅格读出器桩"，给 grid_byte/grid_byte_valid 送已知位图；
//       真实 acx750_grid_reader 就绪后需与此桩的时序约定对齐（见 RTL 头注释）。
//============================================================================
`timescale 1ns/1ps

module tb_m3tl_full;

  // 加速仿真：CLK_HZ=1000 -> TICK_DIV=1（每拍 1 "ms"）
  localparam int CLK_HZ  = 1000;
  localparam int HB_P    = 200;
  localparam int CAM_P   = 300;
  localparam int GRID_P  = 400;

  localparam logic [31:0] UPTIME   = 32'd123456;
  localparam int          ROOT     = 32;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;           // 10 ns 周期

  // --- DUT 端口 ---
  logic [7:0]  stat_flags;
  logic [2:0]  stage;
  logic [31:0] uptime_ms, drop_count;
  logic [31:0] cam_frames, cam_last_ms;
  logic [15:0] cam_width, cam_height;
  logic [7:0]  grid_byte;
  logic        grid_byte_valid;
  logic        grid_snapshot_start, grid_snapshot_done;
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

  assign tx_req = 1'b1;           // 一直拉高：帧 READY 后连续吐出

  acx750_m3tl_full_tx #(
    .CLK_HZ        (CLK_HZ),
    .HB_PERIOD_MS  (HB_P),
    .CAM_PERIOD_MS (CAM_P),
    .GRID_PERIOD_MS(GRID_P)
  ) dut (
    .clk125m(clk), .rst_n(rst_n),
    .stat_flags(stat_flags), .stage(stage), .uptime_ms(uptime_ms), .drop_count(drop_count),
    .cam_frames(cam_frames), .cam_last_ms(cam_last_ms),
    .cam_width(cam_width), .cam_height(cam_height),
    .grid_byte(grid_byte), .grid_byte_valid(grid_byte_valid),
    .grid_snapshot_start(grid_snapshot_start), .grid_snapshot_done(grid_snapshot_done),
    .grid_rows(grid_rows), .grid_cols(grid_cols), .grid_cell_mm(grid_cell_mm),
    .cfg_rb_word_index(cfg_rb_word_index), .cfg_rb_value(cfg_rb_value),
    .cfg_rb_valid(cfg_rb_valid),
    .dst_mac(dst_mac), .dst_ip(dst_ip),
    .tx_start(tx_start), .tx_len(tx_len), .tx_req(tx_req),
    .tx_payload(tx_payload), .tx_busy(tx_busy),
    .tx_pkt_cnt(tx_pkt_cnt), .grid_tx_cnt(grid_tx_cnt)
  );

  //==========================================================================
  // 栅格读出器桩：start -> done(1拍) -> 连续 413 拍送位图
  //==========================================================================
  logic [7:0]  bitmap [0:412];
  logic [15:0] rd_idx;
  logic        rd_done_r;
  logic [2:0]  rd_state;          // 0 idle,1 wait,2 done,3 stream

  wire rd_streaming = (rd_state == 3'd3);
  assign grid_byte       = bitmap[rd_idx[8:0]];
  assign grid_byte_valid = rd_streaming && (rd_idx < 16'd413);
  assign grid_snapshot_done = rd_done_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_state  <= 3'd0;
      rd_idx    <= 16'd0;
      rd_done_r <= 1'b0;
    end else begin
      rd_done_r <= 1'b0;
      case (rd_state)
        3'd0: if (grid_snapshot_start) rd_state <= 3'd1;
        3'd1: begin rd_done_r <= 1'b1; rd_idx <= 16'd0; rd_state <= 3'd2; end
        3'd2: rd_state <= 3'd3;
        3'd3: begin
          if (rd_idx == 16'd412) rd_state <= 3'd0;
          else                   rd_idx   <= rd_idx + 16'd1;
        end
        default: rd_state <= 3'd0;
      endcase
    end
  end

  //==========================================================================
  // 帧抓取：tx_start 后连续抓 tx_len 字节
  //==========================================================================
  logic [7:0]  frame_tmp [0:511];
  logic [15:0] cap_len;
  int          cap_i;
  logic        cap_busy, cap_done;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cap_busy <= 1'b0;
      cap_done <= 1'b0;
      cap_i    <= 0;
      cap_len  <= 16'd0;
    end else begin
      cap_done <= 1'b0;
      if (tx_start) begin
        // tx_start 当拍 idx=0，tx_payload 即 frame_buf[0]，必须先抓住这一拍
        cap_len        <= tx_len;
        frame_tmp[0]   <= tx_payload;
        cap_i          <= 1;
        if (tx_len <= 16'd1) begin
          cap_busy <= 1'b0;
          cap_done <= 1'b1;
        end else begin
          cap_busy <= 1'b1;
        end
      end else if (cap_busy) begin
        frame_tmp[cap_i] <= tx_payload;
        if (cap_i == int'(cap_len) - 1) begin
          cap_busy <= 1'b0;
          cap_done <= 1'b1;
        end else begin
          cap_i <= cap_i + 1;
        end
      end
    end
  end

  //==========================================================================
  // 按 type 分派保存
  //==========================================================================
  logic [7:0]  f_hb0 [0:511], f_hb1 [0:511], f_cam [0:511];
  logic [7:0]  f_g0  [0:511], f_g1  [0:511], f_cfg [0:511];
  logic [15:0] L_hb0, L_hb1, L_cam, L_g0, L_g1, L_cfg;
  int          hb_n, cam_n, g_n, cfg_n;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hb_n <= 0; cam_n <= 0; g_n <= 0; cfg_n <= 0;
    end else if (cap_done) begin
      case (frame_tmp[5])
        8'd1: begin
          if (hb_n == 0)      begin for (int k = 0; k < 512; k++) f_hb0[k] <= frame_tmp[k]; L_hb0 <= cap_len; end
          else if (hb_n == 1) begin for (int k = 0; k < 512; k++) f_hb1[k] <= frame_tmp[k]; L_hb1 <= cap_len; end
          hb_n <= hb_n + 1;
        end
        8'd6: begin
          if (cam_n == 0) begin for (int k = 0; k < 512; k++) f_cam[k] <= frame_tmp[k]; L_cam <= cap_len; end
          cam_n <= cam_n + 1;
        end
        8'd5: begin
          if (g_n == 0)      begin for (int k = 0; k < 512; k++) f_g0[k] <= frame_tmp[k]; L_g0 <= cap_len; end
          else if (g_n == 1) begin for (int k = 0; k < 512; k++) f_g1[k] <= frame_tmp[k]; L_g1 <= cap_len; end
          g_n <= g_n + 1;
        end
        8'd7: begin
          if (cfg_n == 0) begin for (int k = 0; k < 512; k++) f_cfg[k] <= frame_tmp[k]; L_cfg <= cap_len; end
          cfg_n <= cfg_n + 1;
        end
        default: ;
      endcase
    end
  end

  //==========================================================================
  // 检查工具
  //==========================================================================
  int checks, fails;

  function automatic logic [31:0] le32(input logic [7:0] a [0:511], input int off);
    le32 = {a[off+3], a[off+2], a[off+1], a[off]};
  endfunction

  task automatic chk8(input string tag, input logic [7:0] got, input logic [7:0] exp);
    begin
      checks++;
      if (got !== exp) begin fails++; $display("  [FAIL] %-18s got=%02x exp=%02x", tag, got, exp); end
      else                  $display("  [OK]   %-18s = %02x", tag, got);
    end
  endtask

  task automatic chk32(input string tag, input logic [31:0] got, input logic [31:0] exp);
    begin
      checks++;
      if (got !== exp) begin fails++; $display("  [FAIL] %-18s got=%08x exp=%08x", tag, got, exp); end
      else                  $display("  [OK]   %-18s = %08x", tag, got);
    end
  endtask

  task automatic chk_hdr(input string tag, input logic [7:0] a [0:511],
                         input logic [7:0] t, input logic [31:0] plen, input logic [31:0] exp_seq);
    begin
      chk8({tag, ".magic0"}, a[0], 8'h4D);
      chk8({tag, ".magic3"}, a[3], 8'h4C);
      chk8({tag, ".version"}, a[4], 8'h01);
      chk8({tag, ".type"},   a[5], t);
      chk8({tag, ".flags_lo"}, a[6], 8'h00);
      chk8({tag, ".flags_hi"}, a[7], 8'h00);
      chk32({tag, ".payload_len"}, le32(a, 8), plen);
      chk32({tag, ".sequence"},    le32(a, 12), exp_seq);
      chk32({tag, ".timestamp_lo"}, le32(a, 16), UPTIME);
      chk32({tag, ".timestamp_hi"}, le32(a, 20), 32'd0);
    end
  endtask

  // 期望 CRC（Python zlib.crc32 现算）
  localparam logic [31:0] EXP_HB_HDR   = 32'h14efddf6, EXP_HB_PAY   = 32'hf9fe9979;
  localparam logic [31:0] EXP_CAM_HDR  = 32'h1fd4bbeb, EXP_CAM_PAY  = 32'h02e72160;
  localparam logic [31:0] EXP_CFG_HDR  = 32'h1c077734, EXP_CFG_PAY  = 32'h507be2e8;
  localparam logic [31:0] EXP_G0_HDR   = 32'h93c07efd, EXP_G_PAY    = 32'h7735fcad;
  localparam logic [31:0] EXP_G1_HDR   = 32'h08653292;

  //==========================================================================
  // 激励
  //==========================================================================
  initial begin
    stat_flags      = 8'h0B;      // bit0/1/3 置位
    stage           = 3'd5;
    uptime_ms       = UPTIME;
    drop_count      = 32'h00000042;
    cam_frames      = 32'd10;
    cam_last_ms     = 32'd100;
    cam_width       = 16'd640;
    cam_height      = 16'd480;
    grid_rows       = 16'd55;
    grid_cols       = 16'd60;
    grid_cell_mm    = 16'd100;
    cfg_rb_word_index = 32'd0;
    cfg_rb_value      = 32'd0;
    cfg_rb_valid      = 1'b0;
    dst_mac         = 48'h00_0a_35_01_fe_c0;
    dst_ip          = 32'hc0_a8_01_0a;

    // 位图：仅点亮 (0,0) 与 (54,59)
    for (int k = 0; k < 413; k++) bitmap[k] = 8'h00;
    bitmap[0]   = 8'h01;          // 线性下标 0  -> byte0 bit0
    bitmap[412] = 8'h08;          // 线性下标 3299 -> byte412 bit3

    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;

    // 在第一次心跳周期之前打一枪 type=7 回读请求
    repeat (60) @(posedge clk);
    cfg_rb_word_index = 32'd5;
    cfg_rb_value      = 32'hAABBCCDD;
    cfg_rb_valid      = 1'b1;
    @(posedge clk);
    cfg_rb_valid      = 1'b0;

    // 等采集齐全
    wait (hb_n >= 2 && cam_n >= 1 && g_n >= 2 && cfg_n >= 1);
    repeat (20) @(posedge clk);

    run_checks();
    if (fails == 0) $display("\nPASS m3tl_full (%0d checks)", checks);
    else            $display("\nFAIL m3tl_full (%0d/%0d failed)", fails, checks);
    $finish;
  end

  // 看门狗
  initial begin
    repeat (400000) @(posedge clk);
    $display("\nFAIL m3tl_full (timeout: hb_n=%0d cam_n=%0d g_n=%0d cfg_n=%0d)",
             hb_n, cam_n, g_n, cfg_n);
    $finish;
  end

  // 帧记录监视器（打印实际抓到的每帧 type / tx_len）
  initial begin
    forever begin
      @(posedge clk);
      if (cap_done)
        $display("[cap] t=%0t type=%0d tx_len=%0d", $time, frame_tmp[5], cap_len);
    end
  end

  //==========================================================================
  // 检查主体
  //==========================================================================
  task automatic run_checks;
    begin
      checks = 0; fails = 0;
      $display("=== 采集统计: tx_pkt_cnt=%0d grid_tx_cnt=%0d hb=%0d cam=%0d grid=%0d cfg=%0d",
               tx_pkt_cnt, grid_tx_cnt, hb_n, cam_n, g_n, cfg_n);

      //------------------------------------------------------------- type=1
      $display("--- type=1 心跳（回归）---");
      chk32("HB0 tx_len", L_hb0, 16'd48);
      chk_hdr("HB0", f_hb0, 8'd1, 16'd16, 32'd0);
      chk32("HB0 header_crc", le32(f_hb0, 24), EXP_HB_HDR);
      chk32("HB0 payload_crc", le32(f_hb0, 28), EXP_HB_PAY);
      chk8("HB0 p.flags0", f_hb0[32], 8'h01);
      chk8("HB0 p.flags1", f_hb0[33], 8'h01);
      chk8("HB0 p.flags2", f_hb0[34], 8'h00);
      chk8("HB0 p.flags3", f_hb0[35], 8'h01);
      chk8("HB0 p.stage",  f_hb0[36], 8'h05);
      chk32("HB0 p.uptime", {f_hb0[43],f_hb0[42],f_hb0[41],f_hb0[40]}, UPTIME);
      chk32("HB0 p.drops",  {f_hb0[47],f_hb0[46],f_hb0[45],f_hb0[44]}, 32'h42);

      //------------------------------------------------------------- type=6
      $display("--- type=6 相机（回归）---");
      chk32("CAM tx_len", L_cam, 16'd44);
      chk_hdr("CAM", f_cam, 8'd6, 16'd12, 32'd0);
      chk32("CAM header_crc", le32(f_cam, 24), EXP_CAM_HDR);
      chk32("CAM payload_crc", le32(f_cam, 28), EXP_CAM_PAY);
      chk32("CAM p.frames", {f_cam[35],f_cam[34],f_cam[33],f_cam[32]}, 32'd10);
      chk32("CAM p.last_ms",{f_cam[39],f_cam[38],f_cam[37],f_cam[36]}, 32'd100);
      chk32("CAM p.width",  {f_cam[41],f_cam[40]}, 32'd640);
      chk32("CAM p.height", {f_cam[43],f_cam[42]}, 32'd480);

      //------------------------------------------------------------- type=7
      $display("--- type=7 配置回读 ---");
      chk32("CFG tx_len", L_cfg, 16'd40);
      chk_hdr("CFG", f_cfg, 8'd7, 16'd8, 32'd0);
      chk32("CFG header_crc", le32(f_cfg, 24), EXP_CFG_HDR);
      chk32("CFG payload_crc", le32(f_cfg, 28), EXP_CFG_PAY);
      chk32("CFG p.word_index", {f_cfg[35],f_cfg[34],f_cfg[33],f_cfg[32]}, 32'd5);
      chk32("CFG p.value",      {f_cfg[39],f_cfg[38],f_cfg[37],f_cfg[36]}, 32'hAABBCCDD);

      //------------------------------------------------------------- type=5
      $display("--- type=5 栅格 ---");
      chk32("GRID0 tx_len", L_g0, 16'd453);
      chk_hdr("GRID0", f_g0, 8'd5, 16'd421, 32'd0);
      chk32("GRID0 header_crc", le32(f_g0, 24), EXP_G0_HDR);
      chk32("GRID0 payload_crc", le32(f_g0, 28), EXP_G_PAY);
      chk8("GRID0 p.rows", f_g0[32], 8'd55);
      chk8("GRID0 p.cols", f_g0[33], 8'd60);
      chk32("GRID0 p.cell_mm", {f_g0[35],f_g0[34]}, 32'd100);
      chk32("GRID0 p.reserved", {f_g0[39],f_g0[38],f_g0[37],f_g0[36]}, 32'd0);
      chk8("GRID0 bm[0]  (0,0)  ", f_g0[40],  8'h01);
      chk8("GRID0 bm[1]        ", f_g0[41],  8'h00);
      chk8("GRID0 bm[411]      ", f_g0[451], 8'h00);
      chk8("GRID0 bm[412](54,59)", f_g0[452], 8'h08);
      chk32("GRID0 grid_tx_cnt", grid_tx_cnt, 32'd2);

      //----------------------------------------------------- 序号独立性
      $display("--- sequence 独立性 ---");
      chk32("HB1 tx_len", L_hb1, 16'd48);
      chk32("HB1 sequence", le32(f_hb1, 12), 32'd1);
      chk32("HB1 header_crc", le32(f_hb1, 24), 32'h8f4a9199);
      chk32("GRID1 tx_len", L_g1, 16'd453);
      chk32("GRID1 sequence", le32(f_g1, 12), 32'd1);
      chk32("GRID1 header_crc", le32(f_g1, 24), EXP_G1_HDR);
      chk32("GRID1 payload_crc", le32(f_g1, 28), EXP_G_PAY);
    end
  endtask

endmodule

//----------------------------------------------------------------------------
// Python 期望值计算（zlib.crc32）：
//   UPT=123456
//   HB  payload = 01 01 00 01 05 00 00 00 | uptime LE | 42 00 00 00
//       header_crc=0x14efddf6  payload_crc=0xf9fe9979  tx_len=48
//   CAM payload = 0A 00 00 00 64 00 00 00 80 02 E0 01
//       header_crc=0x1fd4bbeb  payload_crc=0x02e72160  tx_len=44
//   CFG payload = 05 00 00 00 DD CC BB AA
//       header_crc=0x1c077734  payload_crc=0x507be2e8  tx_len=40
//   GRID payload = 37 3C 64 00 00 00 00 00 | bitmap(413)
//       首格 byte0=0x01、末格 byte412=0x08
//       seq=0: header_crc=0x93c07efd  payload_crc=0x7735fcad  tx_len=453
//       seq=1: header_crc=0x08653292   payload_crc=0x7735fcad
//----------------------------------------------------------------------------