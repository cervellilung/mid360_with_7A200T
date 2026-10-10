//============================================================================
// tb_cmd -- 串口命令解析自检
//
// 直接向 acx750_cmd 注入 rx_valid/rx_data：
//   * 复位后 stage 应为 STARTUP_STAGE
//   * 依次发 '0'..'7'，stage 应逐个跟随，且不产生 clear_stats 脉冲
//   * 发非法字符（'z'）应被忽略
//   * 发 'c' / 'C' 各产生一个、且宽度恰为 1 个时钟的 clear_stats 脉冲
//
// 自检结论：末行打印 "PASS ..." 或 "FAIL ..."。
//============================================================================
`timescale 1ns/1ps

module tb_cmd;

  localparam logic [2:0] STARTUP = 3'd5;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic       rst_n    = 1'b0;
  logic       rx_valid = 1'b0;
  logic [7:0] rx_data  = 8'h00;
  logic [2:0] stage;
  logic       clear_stats;

  int   errors    = 0;
  int   pulses    = 0;
  logic prev_clear = 1'b0;
  int   width_err = 0;

  acx750_cmd #(.STARTUP_STAGE(STARTUP)) dut (
    .clk         (clk),
    .rst_n       (rst_n),
    .rx_valid    (rx_valid),
    .rx_data     (rx_data),
    .stage       (stage),
    .clear_stats (clear_stats)
  );

  // 统计 clear_stats 脉冲个数与宽度
  always @(posedge clk) begin
    if (clear_stats) pulses = pulses + 1;
    if (clear_stats && prev_clear) width_err = width_err + 1;
    prev_clear <= clear_stats;
  end

  task automatic check(input bit cond, input string msg);
    if (!cond) begin
      errors = errors + 1;
      $display("FAIL cmd: %s", msg);
    end
  endtask

  // 在 clk 低电平期间打一个单周期 rx_valid 脉冲
  task automatic send_char(input logic [7:0] c);
    begin
      @(negedge clk); rx_valid = 1'b1; rx_data = c;
      @(negedge clk); rx_valid = 1'b0;
      @(posedge clk); #1;
    end
  endtask

  integer v;
  logic [2:0] want;

  initial begin
    repeat (4) @(posedge clk);
    #1;
    check(stage === STARTUP, $sformatf("复位默认阶段应为 %0d，实际 %0d", STARTUP, stage));
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    // '0'..'7'
    for (v = 0; v < 8; v = v + 1) begin
      want = v[2:0];
      send_char(8'h30 + v[7:0]);
      check(stage === want, $sformatf("发送 '%0d' 后 stage 应为 %0d，实际 %0d", v, want, stage));
      check(pulses == 0, "'0'..'7' 不应触发 clear_stats");
    end

    // 非法字符忽略
    send_char(8'h7A);   // 'z'
    check(stage === 3'd7, "非法字符不应改变 stage");
    check(pulses == 0, "非法字符不应触发 clear_stats");

    // 'c'
    send_char(8'h63);
    check(stage === 3'd7, "'c' 不应改变 stage");
    check(pulses == 1, $sformatf("发送 'c' 应产生 1 个 clear_stats 脉冲，实际 %0d", pulses));

    // 'C'
    send_char(8'h43);
    check(pulses == 2, $sformatf("发送 'C' 应产生第 2 个 clear_stats 脉冲，实际 %0d", pulses));
    check(width_err == 0, "clear_stats 脉冲宽度必须恰为 1 个时钟");

    if (errors == 0)
      $display("PASS cmd: '0'..'7' 切阶段、'c'/'C' 清统计、非法字符忽略全部正确");
    else
      $display("FAIL cmd: 共 %0d 处错误", errors);
    $finish;
  end

  initial begin
    #500_000;
    $display("FAIL cmd: 仿真超时");
    $finish;
  end

endmodule