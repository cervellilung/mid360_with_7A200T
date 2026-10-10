//============================================================================
// acx750_uart_tx -- 8N1 UART 发送器
//
// 单周期 tx_start 脉冲触发；tx_busy 高期间不得再触发。
// 波特率 = CLK_HZ / BAUD，四舍五入取整。
// 空闲线为高；tx_start 当拍立即拉低起始位。
//============================================================================
`timescale 1ns/1ps

module acx750_uart_tx #(
  parameter int unsigned CLK_HZ = 100_000_000,
  parameter int unsigned BAUD   = 115_200
)(
  input  logic       clk,
  input  logic       rst_n,
  input  logic       tx_start,   // 一个 clk 的脉冲
  input  logic [7:0] tx_data,
  output logic       tx_busy,
  output logic       txd         // 空闲为高
);

  localparam int unsigned DIV = (CLK_HZ + BAUD/2) / BAUD;   // 868 @100MHz/115200
  localparam int unsigned CW  = $clog2(DIV + 1);

  logic [CW-1:0]  div_cnt;
  logic [3:0]     bit_idx;      // 0=start, 1..8=data, 9=stop
  logic [9:0]     shifter;      // {stop, data[7:0], start}
  logic           running;

  wire bit_done = (div_cnt == DIV[CW-1:0] - 1);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      div_cnt <= '0;
      bit_idx <= '0;
      shifter <= 10'h3FF;
      running <= 1'b0;
      txd     <= 1'b1;
    end else if (!running) begin
      div_cnt <= '0;
      bit_idx <= '0;
      txd     <= 1'b1;
      if (tx_start) begin
        shifter <= {1'b1, tx_data, 1'b0};
        txd     <= 1'b0;               // 起始位当拍拉低
        running <= 1'b1;
      end
    end else if (bit_done) begin
      div_cnt <= '0;
      if (bit_idx == 4'd9) begin
        running <= 1'b0;
        txd     <= 1'b1;               // 停止位
      end else begin
        bit_idx <= bit_idx + 4'd1;
        shifter <= {1'b1, shifter[9:1]};
        txd     <= shifter[1];
      end
    end else begin
      div_cnt <= div_cnt + 1'b1;
    end
  end

  assign tx_busy = running;

endmodule