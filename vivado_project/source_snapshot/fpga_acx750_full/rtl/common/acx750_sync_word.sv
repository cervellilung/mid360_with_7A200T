//============================================================================
// acx750_sync_word -- 多位信号跨时钟域同步（2 级触发器）
//
// 适用场景：本工程里跨域的都是"变化很慢的统计计数"（帧计数、误码计数、
// 包计数），位与位之间本来就可能不同步，这里只保证亚稳态不传播，
// 不保证同一拍上取到的值是完全自洽的快照。
// 这些值只用于 HUD 显示与低带宽遥测计数，允许偶发一次"半新半旧"，
// 因此不引入握手/格雷码。**不要**用它传控制信号。
//============================================================================
`timescale 1ns/1ps

module acx750_sync_word #(
  parameter integer WIDTH = 32
)(
  input  logic             clk,
  input  logic             rst_n,
  input  logic [WIDTH-1:0] d,
  output logic [WIDTH-1:0] q
);

  (* ASYNC_REG = "TRUE" *) logic [WIDTH-1:0] s1, s2;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s1 <= '0;
      s2 <= '0;
    end else begin
      s1 <= d;
      s2 <= s1;
    end
  end

  assign q = s2;

endmodule