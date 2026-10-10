//============================================================================
// tb_radar_stream_check.sv —— 雷达字节流异步 FIFO 的**独立自检**
//
// 为什么要另写一个：sim/tb_radar_stream.sv 是在原 agent 被中断前、
// 它自己标注"仿真卡在 PHASE1、正在插桩"的半成品，结论不可信。
// 本台只做一件事：把 N 个已知包从 125 MHz 写侧灌进去，
// 在 100 MHz 读侧按序收回来，逐字节 + 逐包边界比对。
//
// 时序契约（依据 acx750_radar_stream.sv 的实现）：
//   写侧对 eth_valid/eth_data 打一拍得到 v_d/d_d，wr_en = v_d，
//   wr_last = (!eth_valid) || eth_pkt_done —— 即"当前拍 valid 已落"时，
//   把**上一拍**那个字节标记为包尾。
//   => 送包方式：逐字节高 1 拍；包尾那字节之后拉低 eth_valid 至少 1 拍。
//============================================================================
`timescale 1ns/1ps

module tb_radar_stream_check;

  reg  eth_clk = 1'b0;
  reg  clk     = 1'b0;
  reg  eth_rst_n = 1'b0;
  reg  rst_n     = 1'b0;

  reg        eth_valid = 1'b0;
  reg  [7:0] eth_data  = 8'h00;
  reg        eth_pkt_done = 1'b0;

  wire [7:0]  radar_data;
  wire        radar_valid, radar_last;
  wire [31:0] radar_fifo_ovf;

  integer errors = 0;

  acx750_radar_stream dut (
    .eth_clk          (eth_clk),
    .eth_rst_n        (eth_rst_n),
    .eth_valid        (eth_valid),
    .eth_data         (eth_data),
    .eth_pkt_done     (eth_pkt_done),
    .clk              (clk),
    .rst_n            (rst_n),
    .radar_data       (radar_data),
    .radar_valid      (radar_valid),
    .radar_last       (radar_last),
    .fifo_overflow_cnt(radar_fifo_ovf));

  // 125 MHz 写钟、100 MHz 读钟
  always #4 eth_clk = ~eth_clk;
  always #5 clk     = ~clk;

  //--------------------------------------------------------------------------
  // 送一个包：len 个字节，内容是 {包号, 序号}
  //--------------------------------------------------------------------------
  task automatic send_pkt(input [3:0] tag, input integer len);
    integer k;
    begin
      for (k = 0; k < len; k = k + 1) begin
        @(posedge eth_clk);
        eth_valid <= 1'b1;
        eth_data  <= {tag, k[3:0]};        // 高 4 位是包标签，低 4 位是序号
      end
      // 包尾：valid 落下一拍，wr_last 就会落在最后一个字节上
      @(posedge eth_clk);
      eth_valid <= 1'b0;
      @(posedge eth_clk);
      @(posedge eth_clk);
    end
  endtask

  //--------------------------------------------------------------------------
  // 收：把读侧所有 radr_valid 的字节记下来，并记录包边界
  //--------------------------------------------------------------------------
  reg [7:0]  got [0:8191];
  reg        got_last [0:8191];
  integer    n_got = 0;
  integer    n_last = 0;

  always @(posedge clk) begin
    if (rst_n && radar_valid) begin
      got[n_got]      <= radar_data;
      got_last[n_got] <= radar_last;
      n_got           <= n_got + 1;
      if (radar_last) n_last <= n_last + 1;
    end
  end

  integer i;
  initial begin
    $dumpfile("tb_radar_stream_check.vcd");
    $dumpvars(0, tb_radar_stream_check);

    repeat (8) @(posedge eth_clk);
    eth_rst_n <= 1'b1;
    repeat (8) @(posedge clk);
    rst_n     <= 1'b1;
    repeat (8) @(posedge clk);

    // ---- 三包：16 / 1 / 100 字节 ----
    send_pkt(4'hA, 16);
    send_pkt(4'hB, 1);
    send_pkt(4'hC, 100);
    // 等读侧把 FIFO 排空
    repeat (1500) @(posedge clk);

    $display("收到字节数 = %0d（期望 117）", n_got);
    $display("收到包尾数 = %0d（期望 3）", n_last);
    $display("溢出计数   = %0d（期望 0）", radar_fifo_ovf);
    if (n_got !== 117)  begin $display("FAIL: 字节数不符"); errors = errors + 1; end
    if (n_last !== 3)   begin $display("FAIL: 包尾数不符"); errors = errors + 1; end
    if (radar_fifo_ovf !== 0) begin $display("FAIL: 不应溢出"); errors = errors + 1; end

    // ---- 逐字节比对内容 ----
    for (i = 0; i < 16; i = i + 1)
      if (i < n_got && got[i] !== {4'hA, i[3:0]}) begin
        $display("FAIL: 包A 第 %0d 字节 = %02x，期望 %02x", i, got[i], {4'hA, i[3:0]});
        errors = errors + 1;
      end
    if (n_got > 16 && got[16] !== {4'hB, 4'h0}) begin
      $display("FAIL: 包B 首字节 = %02x，期望 b0", got[16]); errors = errors + 1;
    end
    for (i = 0; i < 100; i = i + 1)
      if (17 + i < n_got && got[17+i] !== {4'hC, i[3:0]}) begin
        $display("FAIL: 包C 第 %0d 字节 = %02x，期望 %02x", i, got[17+i], {4'hC, i[3:0]});
        errors = errors + 1;
        if (errors > 5) i = 100;
      end

    // ---- 包尾位置：应恰好是第 15、16、116 号字节 ----
    if (n_got > 15 && !got_last[15]) begin $display("FAIL: 第15字节应是包尾"); errors = errors + 1; end
    if (n_got > 16 && !got_last[16]) begin $display("FAIL: 第16字节应是包尾"); errors = errors + 1; end
    if (n_got > 116 && !got_last[116]) begin $display("FAIL: 第116字节应是包尾"); errors = errors + 1; end

    if (errors == 0) $display("PASS tb_radar_stream_check");
    else             $display("FAIL tb_radar_stream_check: errors=%0d", errors);
    $finish;
  end

  // 防挂死：绝对时间上限
  initial begin
    #400000;
    $display("FAIL: 仿真超时（400us）—— 疑似卡死");
    $finish;
  end

endmodule