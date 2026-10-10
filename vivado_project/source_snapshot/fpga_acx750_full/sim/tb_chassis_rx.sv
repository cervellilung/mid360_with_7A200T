// ============================================================================
// tb_chassis_rx.sv -- acx750_chassis_rx 自检 testbench
//
// 用真实 UART 位流（含起始/停止位）喂 DFLink Odom v4 帧，覆盖：
//   T1 单帧合法：逐字节、valid 拍数(60)、last 恰好 1 次且落在末字节、ok+1
//   T2 连发两帧：ok+2、两帧 120 字节全对
//   T3 CRC 错：bad+1 且不产生 odom_valid
//   T4 半帧停发：超时不卡死，随后正常帧仍能解析
//   T5 中途插垃圾字节：能重新同步找到下一帧
// 两种波特率 460800 / 115200 各跑一遍（用两个 DUT 实例，真实位流）。
// 自检结论：末行打印 "PASS ..." 或 "FAIL ..."。
// ============================================================================
`timescale 1ns/1ps

module tb_chassis_rx;

  localparam int unsigned CLK_HZ  = 100_000_000;
  localparam int unsigned BAUD_F  = 460_800;
  localparam int unsigned BAUD_S  = 115_200;
  localparam int BIT_NS_F = (1000000000 + BAUD_F/2) / BAUD_F;   // 2170
  localparam int BIT_NS_S = (1000000000 + BAUD_S/2) / BAUD_S;   // 8681

  logic clk = 1'b0;
  always #5 clk = ~clk;           // 10 ns -> 100 MHz

  logic rst_n = 1'b0;

  // ---- 快速 DUT (460800) ----
  logic        f_rxd = 1'b1;
  logic [7:0]  f_data;
  logic        f_valid, f_last;
  logic [31:0] f_rx, f_ok, f_bad, f_uart;
  logic [7:0]  f_cap [0:511];
  int          f_capn = 0, f_lastn = 0;

  // ---- 慢速 DUT (115200) ----
  logic        s_rxd = 1'b1;
  logic [7:0]  s_data;
  logic        s_valid, s_last;
  logic [31:0] s_rx, s_ok, s_bad, s_uart;
  logic [7:0]  s_cap [0:511];
  int          s_capn = 0, s_lastn = 0;

  acx750_chassis_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD_F)) dut_fast (
    .clk(clk), .rst_n(rst_n), .chassis_rxd(f_rxd),
    .odom_data(f_data), .odom_valid(f_valid), .odom_last(f_last),
    .rx_byte_cnt(f_rx), .frame_ok_cnt(f_ok),
    .frame_bad_cnt(f_bad), .uart_err_cnt(f_uart)
  );

  acx750_chassis_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD_S)) dut_slow (
    .clk(clk), .rst_n(rst_n), .chassis_rxd(s_rxd),
    .odom_data(s_data), .odom_valid(s_valid), .odom_last(s_last),
    .rx_byte_cnt(s_rx), .frame_ok_cnt(s_ok),
    .frame_bad_cnt(s_bad), .uart_err_cnt(s_uart)
  );

  // 输出捕获
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      f_capn <= 0; f_lastn <= 0;
    end else if (f_valid) begin
      f_cap[f_capn] <= f_data;
      f_capn        <= f_capn + 1;
      if (f_last) f_lastn <= f_lastn + 1;
    end
  end
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s_capn <= 0; s_lastn <= 0;
    end else if (s_valid) begin
      s_cap[s_capn] <= s_data;
      s_capn        <= s_capn + 1;
      if (s_last) s_lastn <= s_lastn + 1;
    end
  end

  // ---- 帧缓存 ----
  logic [7:0] frmA [0:59];
  logic [7:0] frmB [0:59];

  int errors = 0;

  // ---- 工具 ----
  function automatic int get_ok(input bit slow);   get_ok   = slow ? int'(s_ok)   : int'(f_ok);   endfunction
  function automatic int get_bad(input bit slow);  get_bad  = slow ? int'(s_bad)  : int'(f_bad);  endfunction
  function automatic int get_uart(input bit slow); get_uart = slow ? int'(s_uart) : int'(f_uart); endfunction
  function automatic int get_rx(input bit slow);   get_rx   = slow ? int'(s_rx)   : int'(f_rx);   endfunction
  function automatic int get_capn(input bit slow); get_capn = slow ? s_capn      : f_capn;        endfunction
  function automatic int get_lastn(input bit slow);get_lastn= slow ? s_lastn     : f_lastn;       endfunction
  function automatic logic [7:0] get_cap(input bit slow, input int idx);
    get_cap = slow ? s_cap[idx] : f_cap[idx];
  endfunction

  task automatic check(input bit cond, input string msg);
    begin
      if (cond) $display("  [ ok ] %s", msg);
      else begin $display("  [FAIL] %s", msg); errors = errors + 1; end
    end
  endtask

  // 按真实位流发送一个字节
  task automatic send_byte(input logic [7:0] b, input int bit_ns, input bit slow);
    int i;
    begin
      if (slow) s_rxd = 1'b0; else f_rxd = 1'b0;     // 起始位
      #(bit_ns);
      for (i = 0; i < 8; i = i + 1) begin            // 8 数据位 LSB 先
        if (slow) s_rxd = b[i]; else f_rxd = b[i];
        #(bit_ns);
      end
      if (slow) s_rxd = 1'b1; else f_rxd = 1'b1;     // 停止位
      #(bit_ns);
    end
  endtask

  // 构造 DFLink Odom v4 帧（60 字节，校验和 = bytes[0..57] 之和的低 16 位）
  task automatic make_frame(input int sel, input logic [7:0] fill,
                            input logic [15:0] vx, input logic [15:0] vy);
    int i; logic [15:0] cs;
    begin
      if (sel == 0) begin
        frmA[0]=8'hDF; frmA[1]=8'h01; frmA[2]=8'h97;
        frmA[3]=8'h6C; frmA[4]=8'h80; frmA[5]=8'd51; frmA[6]=8'h04;
        for (i = 7; i <= 56; i = i + 1) frmA[i] = fill + i[7:0];
        frmA[25]=vx[7:0]; frmA[26]=vx[15:8];
        frmA[27]=vy[7:0]; frmA[28]=vy[15:8];
        frmA[57]=8'hFD;
        cs = 16'h0000;
        for (i = 0; i <= 57; i = i + 1) cs = cs + frmA[i];
        frmA[58]=cs[7:0]; frmA[59]=cs[15:8];
      end else begin
        frmB[0]=8'hDF; frmB[1]=8'h01; frmB[2]=8'h97;
        frmB[3]=8'h6C; frmB[4]=8'h80; frmB[5]=8'd51; frmB[6]=8'h04;
        for (i = 7; i <= 56; i = i + 1) frmB[i] = fill + i[7:0];
        frmB[25]=vx[7:0]; frmB[26]=vx[15:8];
        frmB[27]=vy[7:0]; frmB[28]=vy[15:8];
        frmB[57]=8'hFD;
        cs = 16'h0000;
        for (i = 0; i <= 57; i = i + 1) cs = cs + frmB[i];
        frmB[58]=cs[7:0]; frmB[59]=cs[15:8];
      end
    end
  endtask

  task automatic send_frame(input bit slow, input int bit_ns, input int sel);
    int i; logic [7:0] b;
    begin
      for (i = 0; i < 60; i = i + 1) begin
        b = (sel == 0) ? frmA[i] : frmB[i];
        send_byte(b, bit_ns, slow);
      end
    end
  endtask

  task automatic send_partial(input bit slow, input int bit_ns, input int sel, input int n);
    int i; logic [7:0] b;
    begin
      for (i = 0; i < n; i = i + 1) begin
        b = (sel == 0) ? frmA[i] : frmB[i];
        send_byte(b, bit_ns, slow);
      end
    end
  endtask

  // ---- 一组完整测试，slow 选择 DUT，bit_ns 为位时间 ----
  task automatic run_tests(input bit slow, input int bit_ns, input string tag);
    int base_ok, base_bad, base_uart, base_cap, base_last, k; logic okay;
    begin
      $display("==== %s (BAUD=%s, bit=%0d ns) ====", tag,
               slow ? "115200" : "460800", bit_ns);

      // -- T1 单帧合法 --
      base_ok=get_ok(slow); base_bad=get_bad(slow); base_cap=get_capn(slow); base_last=get_lastn(slow);
      send_frame(slow, bit_ns, 0);
      #(bit_ns*3);
      $display("  T1 计数: ok=%0d bad=%0d uart=%0d rx=%0d beats=%0d last=%0d",
               get_ok(slow), get_bad(slow), get_uart(slow), get_rx(slow),
               get_capn(slow)-base_cap, get_lastn(slow)-base_last);
      check((get_ok(slow)-base_ok)==1,   "T1 frame_ok_cnt +1");
      check((get_bad(slow)-base_bad)==0, "T1 frame_bad_cnt +0");
      check((get_capn(slow)-base_cap)==60, "T1 odom_valid 拍数==60(帧长)");
      check((get_lastn(slow)-base_last)==1, "T1 odom_last 恰好 1 次");
      okay=1'b1;
      for (k=0;k<60;k=k+1) if (get_cap(slow,base_cap+k)!==frmA[k]) okay=1'b0;
      check(okay, "T1 odom_data 逐字节与发送帧一致");

      // -- T2 连发两帧 --
      base_ok=get_ok(slow); base_cap=get_capn(slow); base_last=get_lastn(slow);
      send_frame(slow, bit_ns, 0);
      send_frame(slow, bit_ns, 1);
      #(bit_ns*3);
      $display("  T2 计数: ok=%0d beats=%0d last=%0d",
               get_ok(slow), get_capn(slow)-base_cap, get_lastn(slow)-base_last);
      check((get_ok(slow)-base_ok)==2,     "T2 frame_ok_cnt +2");
      check((get_capn(slow)-base_cap)==120, "T2 两帧共 120 拍 valid");
      check((get_lastn(slow)-base_last)==2, "T2 odom_last 2 次");
      okay=1'b1;
      for (k=0;k<60;k=k+1) if (get_cap(slow,base_cap+k)!==frmA[k]) okay=1'b0;
      for (k=0;k<60;k=k+1) if (get_cap(slow,base_cap+60+k)!==frmB[k]) okay=1'b0;
      check(okay, "T2 两帧数据都正确");

      // -- T3 CRC 错 --
      frmA[59] = frmA[59] ^ 8'hFF;             // 破坏校验和高字节
      base_ok=get_ok(slow); base_bad=get_bad(slow); base_cap=get_capn(slow);
      send_frame(slow, bit_ns, 0);
      #(bit_ns*3);
      $display("  T3 计数: ok=+%0d bad=+%0d beats=+%0d",
               get_ok(slow)-base_ok, get_bad(slow)-base_bad, get_capn(slow)-base_cap);
      check((get_bad(slow)-base_bad)==1,   "T3 frame_bad_cnt +1");
      check((get_ok(slow)-base_ok)==0,     "T3 不产生 frame_ok");
      check((get_capn(slow)-base_cap)==0,  "T3 不产生 odom_valid");
      make_frame(0, 8'h10, 16'h1234, 16'h5678);  // 复原 A

      // -- T4 半帧停发 + 超时恢复 --
      base_uart=get_uart(slow); base_ok=get_ok(slow); base_cap=get_capn(slow);
      send_partial(slow, bit_ns, 0, 30);       // 只发 30 字节
      #(bit_ns*20);                            // 等超时（>14 比特）
      $display("  T4 半帧后: uart=+%0d beats=+%0d",
               get_uart(slow)-base_uart, get_capn(slow)-base_cap);
      check((get_uart(slow)-base_uart)>=1, "T4 断流超时计入 uart_err_cnt");
      check((get_capn(slow)-base_cap)==0,  "T4 半帧不产生 valid");
      // 随后一整帧仍应解析
      base_ok=get_ok(slow); base_cap=get_capn(slow);
      send_frame(slow, bit_ns, 1);
      #(bit_ns*3);
      $display("  T4 恢复后: ok=+%0d beats=+%0d", get_ok(slow)-base_ok, get_capn(slow)-base_cap);
      check((get_ok(slow)-base_ok)==1,     "T4 超时后正常帧 frame_ok +1");
      check((get_capn(slow)-base_cap)==60, "T4 超时后正常帧 60 拍");
      okay=1'b1;
      for (k=0;k<60;k=k+1) if (get_cap(slow,base_cap+k)!==frmB[k]) okay=1'b0;
      check(okay, "T4 超时后恢复帧数据正确");

      // -- T5 中途插垃圾字节，重新同步 --
      base_bad=get_bad(slow); base_ok=get_ok(slow); base_cap=get_capn(slow);
      send_byte(frmA[0], bit_ns, slow);        // 帧头段
      send_byte(frmA[1], bit_ns, slow);
      send_byte(frmA[2], bit_ns, slow);
      send_byte(8'h00,  bit_ns, slow);         // index3 垃圾(应=0x6C) -> bad
      send_frame(slow, bit_ns, 1);             // 紧接着一整帧 B
      #(bit_ns*3);
      $display("  T5 计数: bad=+%0d ok=+%0d beats=+%0d",
               get_bad(slow)-base_bad, get_ok(slow)-base_ok, get_capn(slow)-base_cap);
      check((get_bad(slow)-base_bad)==1,   "T5 垃圾字节计入 frame_bad_cnt");
      check((get_ok(slow)-base_ok)==1,     "T5 重新同步后 frame_ok +1");
      check((get_capn(slow)-base_cap)==60, "T5 重新同步帧 60 拍");
      okay=1'b1;
      for (k=0;k<60;k=k+1) if (get_cap(slow,base_cap+k)!==frmB[k]) okay=1'b0;
      check(okay, "T5 重新同步帧数据正确");
    end
  endtask

  initial begin
    rst_n = 1'b0;
    repeat (8) @(posedge clk);
    rst_n = 1'b1;
    repeat (4) @(posedge clk);

    make_frame(0, 8'h10, 16'h1234, 16'h5678);   // 帧 A
    make_frame(1, 8'h80, 16'hFF01, 16'h00FE);   // 帧 B
    $display("帧A 校验和 = 0x%02X%02X, 帧B 校验和 = 0x%02X%02X",
             frmA[59], frmA[58], frmB[59], frmB[58]);

    run_tests(1'b0, BIT_NS_F, "DUT_fast");   // slow=0 -> 460800 实例
    run_tests(1'b1, BIT_NS_S, "DUT_slow");   // slow=1 -> 115200 实例

    $display("----------------------------------------------");
    if (errors == 0)
      $display("PASS  acx750_chassis_rx 全部自检通过 (0 error)");
    else
      $display("FAIL  acx750_chassis_rx 共 %0d 项失败", errors);
    $finish;
  end

endmodule