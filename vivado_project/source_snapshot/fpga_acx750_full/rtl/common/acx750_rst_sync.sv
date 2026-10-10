//============================================================================
// acx750_rst_sync -- 把低有效复位同步到目标时钟域
//
// 异步置位、同步释放。用于把系统域复位搬到像素钟/以太网钟等其它域。
//============================================================================
`timescale 1ns/1ps

module acx750_rst_sync (
  input  logic clk,
  input  logic arst_n,     // 源域低有效复位，异步
  output logic rst_n       // 本域低有效复位
);

  (* ASYNC_REG = "TRUE" *) logic [1:0] sync;
  always_ff @(posedge clk or negedge arst_n) begin
    if (!arst_n)
      sync <= 2'b00;
    else
      sync <= {sync[0], 1'b1};
  end

  assign rst_n = sync[1];

endmodule