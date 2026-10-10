//============================================================================
// acx750_uart_rx -- 8N1 UART 接收器
//
// 状态机：IDLE -> START(中点确认) -> DATA(每位中点采样) -> STOP
// rx_data_valid 是一个 clk 的脉冲。用于接收 PC/上位机发来的调试命令。
//============================================================================
`timescale 1ns/1ps

module acx750_uart_rx #(
  parameter int unsigned CLK_HZ = 100_000_000,
  parameter int unsigned BAUD   = 115_200
)(
  input  logic       clk,
  input  logic       rst_n,
  input  logic       rxd,           // 空闲为高
  output logic [7:0] rx_data,
  output logic       rx_data_valid
);

  localparam int unsigned DIV = (CLK_HZ + BAUD/2) / BAUD;
  localparam int unsigned HW  = DIV / 2;
  localparam int unsigned CW  = $clog2(DIV + 1);

  localparam logic [1:0] S_IDLE = 2'd0, S_START = 2'd1, S_DATA = 2'd2, S_STOP = 2'd3;

  (* ASYNC_REG = "TRUE" *) logic [1:0] rxd_sync;
  logic          rxd_meta;
  logic [1:0]    state;
  logic [CW-1:0] div_cnt;
  logic [2:0]    bit_idx;
  logic [7:0]    shifter;

  wire falling = rxd_meta && !rxd_sync[0];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rxd_sync      <= 2'b11;
      rxd_meta      <= 1'b1;
      state         <= S_IDLE;
      div_cnt       <= '0;
      bit_idx       <= '0;
      shifter       <= '0;
      rx_data       <= '0;
      rx_data_valid <= 1'b0;
    end else begin
      rxd_sync <= {rxd_sync[0], rxd};
      rxd_meta <= rxd_sync[1];
      rx_data_valid <= 1'b0;

      case (state)
        S_IDLE: begin
          div_cnt <= '0;
          bit_idx <= '0;
          if (falling)
            state <= S_START;
        end

        S_START: begin
          if (div_cnt == HW[CW-1:0] - 1) begin
            div_cnt <= '0;
            // 起始位中点应为低；否则判为毛刺，丢弃
            state <= rxd_meta ? S_IDLE : S_DATA;
          end else begin
            div_cnt <= div_cnt + 1'b1;
          end
        end

        S_DATA: begin
          if (div_cnt == DIV[CW-1:0] - 1) begin
            div_cnt <= '0;
            shifter <= {rxd_meta, shifter[7:1]};
            if (bit_idx == 3'd7)
              state <= S_STOP;
            else
              bit_idx <= bit_idx + 3'd1;
          end else begin
            div_cnt <= div_cnt + 1'b1;
          end
        end

        S_STOP: begin
          if (div_cnt == DIV[CW-1:0] - 1) begin
            div_cnt       <= '0;
            rx_data       <= shifter;   // 8 位数据采样已完成（S_DATA 里已收 8 位）
            rx_data_valid <= 1'b1;
            state         <= S_IDLE;
          end else begin
            div_cnt <= div_cnt + 1'b1;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule