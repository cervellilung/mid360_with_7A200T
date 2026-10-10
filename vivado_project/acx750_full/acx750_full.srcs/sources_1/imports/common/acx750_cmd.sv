//============================================================================
// acx750_cmd -- UART 单字符调试命令解析
//
// 上电后默认阶段由 STARTUP_STAGE 决定；收到 '0'..'7' 就切到对应阶段。
// 另外支持：
//   '?'  打印一行帮助
//   'c'  清空所有统计计数器
// 其余字符忽略。
//
// 这样只需一条 bitstream 就能在板上逐级走 debug 流程，不必每级重综合。
//============================================================================
`timescale 1ns/1ps

module acx750_cmd #(
  parameter logic [2:0] STARTUP_STAGE = 3'd0
)(
  input  logic       clk,
  input  logic       rst_n,
  input  logic       rx_valid,
  input  logic [7:0] rx_data,

  output logic [2:0] stage,
  output logic       clear_stats   // 单周期脉冲
);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      stage       <= STARTUP_STAGE;
      clear_stats <= 1'b0;
    end else begin
      clear_stats <= 1'b0;
      if (rx_valid) begin
        if (rx_data >= 8'h30 && rx_data <= 8'h37)      // '0'..'7'
          stage <= rx_data[2:0];
        else if (rx_data == 8'h63 || rx_data == 8'h43) // 'c' / 'C'
          clear_stats <= 1'b1;
      end
    end
  end

endmodule