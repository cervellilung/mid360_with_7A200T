//============================================================================
// tb_uart_loopback -- UART 自发自收回环自检
//
// 把 acx750_uart_tx 的 txd 直接接到 acx750_uart_rx 的 rxd，发若干个字节
// （含 0x00/0xFF/0x55/0xAA 等边界值），校验收到的与发出的完全一致。
//
// 为加快仿真，用很小的 CLK_HZ=1_000_000、BAUD=100_000（DIV=10，整数精确）。
// 自检结论：末行打印 "PASS ..." 或 "FAIL ..."。
//============================================================================
`timescale 1ns/1ps

module tb_uart_loopback;

  localparam int unsigned CLK_HZ = 1_000_000;
  localparam int unsigned BAUD   = 100_000;
  localparam int unsigned DIV    = (CLK_HZ + BAUD/2) / BAUD;   // = 10

  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic       rst_n    = 1'b0;
  logic       tx_start = 1'b0;
  logic [7:0] tx_data  = 8'h00;
  logic       tx_busy;
  logic       txd;

  logic [7:0] rx_data;
  logic       rx_data_valid;

  localparam int unsigned NB = 11;
  logic [7:0] sent [0:NB-1];
  logic [7:0] recv [0:NB-1];
  int unsigned got = 0;
  int          errors = 0;

  acx750_uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
    .clk      (clk),
    .rst_n    (rst_n),
    .tx_start (tx_start),
    .tx_data  (tx_data),
    .tx_busy  (tx_busy),
    .txd      (txd)
  );

  acx750_uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_rx (
    .clk           (clk),
    .rst_n         (rst_n),
    .rxd           (txd),          // 回环
    .rx_data       (rx_data),
    .rx_data_valid (rx_data_valid)
  );

  always @(posedge clk) begin
    if (rx_data_valid && got < NB) begin
      recv[got] = rx_data;
      got       = got + 1;
    end
  end

  task automatic check(input bit cond, input string msg);
    if (!cond) begin
      errors = errors + 1;
      $display("FAIL uart_loopback: %s", msg);
    end
  endtask

  integer k;

  initial begin
    sent[0]  = 8'h00;   // 全 0
    sent[1]  = 8'hFF;   // 全 1
    sent[2]  = 8'h55;   // 0101_0101
    sent[3]  = 8'hAA;   // 1010_1010
    sent[4]  = 8'h01;
    sent[5]  = 8'h80;
    sent[6]  = 8'h7F;
    sent[7]  = 8'h7E;
    sent[8]  = 8'h12;
    sent[9]  = 8'h34;
    sent[10] = 8'hC3;

    repeat (8) @(posedge clk);
    rst_n = 1'b1;
    repeat (4) @(posedge clk);
    check(txd === 1'b1, "复位后空闲线应为高电平");

    for (k = 0; k < NB; k = k + 1) begin
      @(negedge clk);
      tx_start = 1'b1;
      tx_data  = sent[k];
      @(negedge clk);
      tx_start = 1'b0;
      wait (got == k + 1);            // 本字节已被接收
      wait (tx_busy === 1'b0);        // 等待发送器回到空闲
      repeat (2) @(posedge clk);
    end

    repeat (20) @(posedge clk);

    check(got == NB, $sformatf("接收字节数 %0d，期望 %0d", got, NB));
    for (k = 0; k < NB; k = k + 1)
      if (recv[k] !== sent[k])
        check(1'b0, $sformatf("第 %0d 字节收到 %02x，期望 %02x", k, recv[k], sent[k]));

    if (errors == 0)
      $display("PASS uart_loopback: %0d 字节（含 00/FF/55/AA 边界）回环收发完全一致", NB);
    else
      $display("FAIL uart_loopback: 共 %0d 处错误", errors);
    $finish;
  end

  initial begin
    #2_000_000;
    $display("FAIL uart_loopback: 仿真超时（未在预期时间内完成）");
    $finish;
  end

endmodule