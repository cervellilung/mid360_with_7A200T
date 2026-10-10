//============================================================================
// tb_self_pattern -- DDR3 自检图案自检
//
// acx750_self_pattern 是纯组合逻辑 (x,y) -> rgb，必须与帧号无关：
// 写侧/读侧各自按帧循环，只有"同一 (x,y) 结果恒定"自检才成立。
//
// 本台做两件事：
//   1. 抽查三个区间的已知点（棋盘 / 绿色行号 / 红蓝斜率）
//   2. 对若干坐标在不同"帧"（重复求值）下结果必须完全一致
//
// 自检结论：末行打印 "PASS ..." 或 "FAIL ..."。
//============================================================================
`timescale 1ns/1ps

module tb_self_pattern;

  logic [11:0] x = 12'd0;
  logic [11:0] y = 12'd0;
  logic [15:0] rgb;

  int errors = 0;
  int frame;

  acx750_self_pattern dut (
    .x   (x),
    .y   (y),
    .rgb (rgb)
  );

  task automatic chk_point(input logic [11:0] xa, input logic [11:0] ya,
                           input logic [15:0] exp, input string region);
    begin
      x = xa; y = ya; #1;
      if (rgb !== exp) begin
        errors = errors + 1;
        $display("FAIL self_pattern: (%0d,%0d) %s 期望 %04x 实际 %04x",
                 xa, ya, region, exp, rgb);
      end
    end
  endtask

  // 三个区间的已知点
  task automatic known_points();
    begin
      // --- 区间 1：x < 400，16 像素黑白棋盘 rgb = checker ? FFFF : 0000 ---
      chk_point(   0,    0, 16'h0000, "棋盘");
      chk_point(  16,    0, 16'hFFFF, "棋盘");
      chk_point(   0,   16, 16'hFFFF, "棋盘");
      chk_point(  16,   16, 16'h0000, "棋盘");
      chk_point(  31,   31, 16'h0000, "棋盘");
      chk_point(  20,    4, 16'hFFFF, "棋盘");
      chk_point(   5,    4, 16'h0000, "棋盘");
      chk_point( 399,    0, 16'h0000, "棋盘(上界内侧)");
      chk_point( 399,   16, 16'hFFFF, "棋盘(上界内侧)");

      // --- 区间 2：400..599，绿色行号 rgb = {5'h00, y[5:0], 5'h00} ---
      // 即 y[5:0] 落在 RGB565 的绿色位段 bit10:5，故数值 = y[5:0] * 32
      chk_point( 400,    0, 16'h0000, "绿色行号(下界)");
      chk_point( 400,   42, 16'h0540, "绿色行号");
      chk_point( 599,   42, 16'h0540, "绿色行号(上界内侧)");
      chk_point( 599,   63, 16'h07E0, "绿色行号(纯绿)");
      chk_point( 500,  255, 16'h07E0, "绿色行号(仅取 y[5:0])");
      chk_point( 450, 12'h142, 16'h0040, "绿色行号(高位忽略)");

      // --- 区间 3：x >= 600，红=列斜率/蓝=行斜率 rgb = {x[4:0],6'h00,y[4:0]} ---
      chk_point( 600,    0, 16'hC000, "红蓝斜率(下界)");
      chk_point( 600,    1, 16'hC001, "红蓝斜率");
      chk_point( 600,   31, 16'hC01F, "红蓝斜率");
      chk_point( 633,   31, 16'hC81F, "红蓝斜率");
      chk_point(1023,    0, 16'hF800, "红蓝斜率(列低位满)");
      chk_point(2047, 2047, 16'hF81F, "红蓝斜率(低位全 1)");
    end
  endtask

  // 帧一致性：同一坐标在不同"帧"重复求值必须完全一致
  task automatic frame_consistency(input logic [11:0] xa, input logic [11:0] ya);
    logic [15:0] ref_val;
    int f;
    begin
      x = xa; y = ya; #1; ref_val = rgb;
      for (f = 0; f < 5; f = f + 1) begin
        #7;                       // 推进时间，模拟进入另一帧
        x = xa; y = ya; #1;
        if (rgb !== ref_val) begin
          errors = errors + 1;
          $display("FAIL self_pattern: (%0d,%0d) 第 %0d 帧结果 %04x != 首帧 %04x",
                   xa, ya, f + 1, rgb, ref_val);
        end
      end
    end
  endtask

  initial begin
    // 不同帧下重复求值
    frame_consistency(  16,   16);   // 棋盘
    frame_consistency( 432,   77);   // 绿色行号
    frame_consistency( 700,  139);   // 红蓝斜率

    // 已知点连查 4 帧，验证结果与帧无关
    for (frame = 0; frame < 4; frame = frame + 1) begin
      known_points();
      #5;
    end

    if (errors == 0)
      $display("PASS self_pattern: 三区间已知点、以及 (x,y) 结果与帧号无关全部正确");
    else
      $display("FAIL self_pattern: 共 %0d 处错误", errors);
    $finish;
  end

  initial begin
    #200_000;
    $display("FAIL self_pattern: 仿真超时");
    $finish;
  end

endmodule