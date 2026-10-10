//============================================================================
// tb_reset -- 复位同步/展宽自检
//
// 校验 acx750_reset：
//   1. 上电（按键按下、locked=0）时 rst_n 必须为 0
//   2. locked=0 时即使松开按键，rst_n 仍保持 0
//   3. locked=1 且按键释放后，要经过 >= DEBOUNCE_CLK 个时钟才拉高
//   4. 按键再次按下，rst_n 应很快拉低
//   5. 再次释放后，重新经过去抖再拉高
//
// 为加快仿真，DEBOUNCE_CLK 取 16。
// 自检结论：末行打印 "PASS ..." 或 "FAIL ..."。
//============================================================================
`timescale 1ns/1ps

module tb_reset;

  localparam int unsigned DEBOUNCE = 16;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic locked      = 1'b0;
  logic btn_reset_n = 1'b0;   // 低有效，按下 = 0
  logic rst_n;

  int errors = 0;
  int cycles = 0;

  acx750_reset #(.DEBOUNCE_CLK(DEBOUNCE)) dut (
    .clk         (clk),
    .locked      (locked),
    .btn_reset_n (btn_reset_n),
    .rst_n       (rst_n)
  );

  task automatic check(input bit cond, input string msg);
    if (!cond) begin
      errors = errors + 1;
      $display("FAIL reset: %s", msg);
    end
  endtask

  initial begin
    // 1) 上电：按键按下、locked=0
    btn_reset_n = 1'b0;
    locked      = 1'b0;
    repeat (10) @(posedge clk); #1;
    check(rst_n === 1'b0, "上电（按键按下、locked=0）rst_n 应为 0");

    // 2) 松开按键但 locked 仍为 0
    btn_reset_n = 1'b1;
    repeat (4 * DEBOUNCE) @(posedge clk); #1;
    check(rst_n === 1'b0, "locked=0 时松开按键，rst_n 仍应保持 0");

    // 3) locked=1 后需要 >= DEBOUNCE_CLK 才释放
    locked = 1'b1;
    cycles = 0;
    @(negedge clk);
    while ((rst_n !== 1'b1) && (cycles <= 4 * DEBOUNCE + 40)) begin
      @(posedge clk); #1;
      cycles = cycles + 1;
      if (cycles == DEBOUNCE / 2)
        check(rst_n === 1'b0, "去抖计数过半时 rst_n 不应拉高");
    end
    check(rst_n === 1'b1, "locked=1 且按键释放后 rst_n 应最终拉高");
    check(cycles >= DEBOUNCE,
          $sformatf("释放延迟 %0d 必须 >= DEBOUNCE_CLK=%0d", cycles, DEBOUNCE));
    check(cycles <= DEBOUNCE + 8,
          $sformatf("释放延迟 %0d 不应远大于 DEBOUNCE_CLK=%0d", cycles, DEBOUNCE));

    // 4) 再次按下 → 很快拉低
    @(negedge clk);
    btn_reset_n = 1'b0;
    repeat (6) @(posedge clk); #1;
    check(rst_n === 1'b0, "按键再次按下后 rst_n 应立刻拉低");

    // 5) 再次释放 → 重新去抖后拉高
    btn_reset_n = 1'b1;
    cycles = 0;
    while ((rst_n !== 1'b1) && (cycles <= 4 * DEBOUNCE + 40)) begin
      @(posedge clk); #1;
      cycles = cycles + 1;
    end
    check(rst_n === 1'b1, "再次释放后 rst_n 应重新拉高");
    check(cycles >= DEBOUNCE, "第二次释放延迟同样应 >= DEBOUNCE_CLK");

    if (errors == 0)
      $display("PASS reset: locked/按键保持复位、去抖展宽释放、再次按下立即复位全部正确");
    else
      $display("FAIL reset: 共 %0d 处错误", errors);
    $finish;
  end

  initial begin
    #500_000;
    $display("FAIL reset: 仿真超时");
    $finish;
  end

endmodule