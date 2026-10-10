//============================================================================
// tb_grid_reader -- acx750_grid_reader + perception_engine 栅格只读透传自检
//
// 目的：
//   * 直接例化 perception_engine（而不是单独 lidar_grid），验证从 perception_engine
//     顶层端口 grid_rd_addr/grid_rd_data 能真正访问到内部 lidar_grid 的栅格
//     （"够不到"问题的回归）。
//   * 在内部 lidar_grid 的 bank0 里人为写入一个**非对称**图案：
//       外部第 3 行第 7 列、外部第 10 行第 2 列  ->  置 1，其余为 0。
//     非对称图案才能测出转置方向是否搞反。
//   * 跑一次快照，按 M3TL type=5 约定（55 行 x 60 列，n=r*60+c，byte n>>3 的
//     bit(n&7)）检查位图，并验证 done 在 413 字节之前（握手契约）。
//
// 判定：末尾打印 PASS / FAIL。
//============================================================================
`timescale 1ns/1ps
`include "perception_types.svh"
module tb_grid_reader;

  reg clk = 0;
  always #5 clk = ~clk;          // 100 MHz 控制域

  reg rst = 1;                   // perception_engine / lidar_grid 的 rst 为高有效

  // perception_engine 端口
  reg  [63:0]   now_us = 64'd0;
  reg  [7:0]    radar_data = 8'h00;
  reg           radar_valid = 0, radar_last = 0;
  reg  [7:0]    odom_data = 8'h00;
  reg           odom_valid = 0, odom_last = 0;
  reg  [31:0]   src6 = 32'd0;
  reg  [2047:0] cfg = 2048'd0;
  reg  [7071:0] lut = 7072'd0;
  reg           cfg_pending = 0;
  wire          cfg_safe;
  wire          snapshot_start;
  wire [1023:0] metadata;
  reg  [4:0]    snapshot_index = 5'd0;
  reg           snapshot_busy = 0;
  wire [383:0]  snapshot_object;
  wire [7:0]    grid_rd_data;
  reg           video_clk = 0, video_rst = 0;
  reg  [15:0]   video_data = 16'd0;
  reg           video_valid = 0, video_sof = 0, video_eol = 0;
  wire          video_ready;
  wire [15:0]   out_data;
  wire          out_valid, out_sof, out_eol;

  // 栅格读出器
  wire [11:0] rd_addr_w;
  wire        rd_busy, rd_done, rd_byte_valid;
  wire [7:0]  rd_byte_out;
  wire [15:0] rd_byte_index;

  perception_engine u_engine (
    .clk(clk), .rst(rst), .now_us(now_us),
    .radar_data(radar_data), .radar_valid(radar_valid), .radar_last(radar_last),
    .odom_data(odom_data), .odom_valid(odom_valid), .odom_last(odom_last),
    .source_fifo_overflow(src6), .source_eth_rejected(src6), .source_odom_bad(src6),
    .source_odom_busy(src6), .source_radar_slot_drops(src6), .source_chassis_slot_drops(src6),
    .cfg(cfg), .lut(lut), .cfg_pending(cfg_pending), .cfg_safe(cfg_safe),
    .snapshot_start(snapshot_start), .metadata(metadata),
    .snapshot_index(snapshot_index), .snapshot_busy(snapshot_busy), .snapshot_object(snapshot_object),
    .grid_rd_addr(rd_addr_w), .grid_rd_data(grid_rd_data),
    .video_clk(video_clk), .video_rst(video_rst),
    .video_data(video_data), .video_valid(video_valid), .video_sof(video_sof), .video_eol(video_eol),
    .video_ready(video_ready),
    .out_data(out_data), .out_valid(out_valid), .out_sof(out_sof), .out_eol(out_eol),
    .out_ready(1'b1)
  );

  // 声明必须在使用之前（Verilog 里用后再声明会被当隐式网线，报 VRFC 10-2938）
  reg         rd_start = 0;
  wire [15:0] rd_addr_dbg;

  acx750_grid_reader u_reader (
    .clk(clk), .rst_n(~rst),
    .start(rd_start),
    .busy(rd_busy), .done(rd_done),
    .rd_addr(rd_addr_dbg),
    .byte_out(rd_byte_out), .byte_valid(rd_byte_valid), .byte_index(rd_byte_index),
    .grid_rd_addr(rd_addr_w), .grid_rd_data(grid_rd_data)
  );

  // （rd_start / rd_addr_dbg 已提前声明，见上面 u_reader 之前）

  // 捕获位图
  reg [7:0] bmp [0:412];
  integer   seen = 0;

  always @(posedge clk) if (rd_byte_valid) begin
    if (rd_byte_index < 413) bmp[rd_byte_index] = rd_byte_out;
    seen = seen + 1;
  end

  integer i, n, errs, guard;
  reg exp_bit, got_bit;

  initial begin
    errs = 0;
    for (i = 0; i < 413; i = i + 1) bmp[i] = 8'h00;

    rst = 1'b1;
    repeat (10) @(posedge clk);
    rst = 1'b0;

    // 等 lidar_grid 初始化完成（内部把两 bank 清零）
    guard = 0;
    while (u_engine.grid.initialized !== 1'b1 && guard < 200000) begin
      @(posedge clk); guard = guard + 1;
    end
    if (u_engine.grid.initialized !== 1'b1) begin
      $display("FAIL grid_reader: lidar_grid 初始化未完成");
      $finish;
    end
    $display("DBG: lidar_grid 初始化完成 (guard=%0d)", guard);

    // 人为写入非对称图案（内部 idx = c*55 + r）：
    //   外部 (r=3,c=7) -> idx = 7*55+3  = 388
    //   外部 (r=10,c=2)-> idx = 2*55+10 = 120
    u_engine.grid.bank0.memory[388] = {8'd1, 225'd0};   // count=1
    u_engine.grid.bank0.memory[120] = {8'd1, 225'd0};
    repeat (4) @(posedge clk);

    // 触发一次快照
    @(negedge clk); rd_start = 1'b1;
    @(negedge clk); rd_start = 1'b0;

    // 等 done（应在字节流之前）
    guard = 0;
    while (!rd_done && guard < 200000) begin @(posedge clk); guard = guard + 1; end
    $display("DBG: done 在 %0d 拍出现, 此刻 seen(字节数)=%0d", guard, seen);

    // 等 413 字节收完
    guard = 0;
    while ((rd_byte_valid || seen < 413) && guard < 200000) begin
      @(posedge clk); guard = guard + 1;
    end
    repeat (4) @(posedge clk);

    $display("DBG: 收到字节数=%0d (应为 413)", seen);

    // 校验位图
    if (seen != 413) begin
      $display("FAIL grid_reader: 字节数 %0d != 413", seen);
      errs = errs + 1;
    end
    for (n = 0; n < 3300; n = n + 1) begin
      exp_bit = (n == 187) || (n == 602);            // (3*60+7) 和 (10*60+2)
      got_bit = (bmp[n >> 3] >> (n & 7)) & 1'b1;
      if (got_bit !== exp_bit) begin
        errs = errs + 1;
        if (errs <= 10)
          $display("FAIL bit n=%0d: got=%0b exp=%0b", n, got_bit, exp_bit);
      end
    end

    // 打印置位位置，便于人工核对转置方向
    for (n = 0; n < 3300; n = n + 1) begin
      if (((bmp[n >> 3] >> (n & 7)) & 1'b1) === 1'b1)
        $display("DBG: 位置 n=%0d 置 1 (r=%0d,c=%0d)", n, n/60, n%60);
    end

    if (errs == 0) $display("PASS tb_grid_reader");
    else           $display("FAIL tb_grid_reader: errors=%0d", errs);
    $finish;
  end

  initial begin
    #2000000;
    $display("FAIL tb_grid_reader: timeout");
    $finish;
  end

endmodule