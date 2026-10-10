//============================================================================
// acx750_uart_report -- 周期把板卡状态打成一行 ASCII 从串口输出
//
// 输出格式（每 PERIOD_MS 一次，115200 8N1）：
//   S=<stage> PLL=<0/1> DDR=<0/1> CAM=<0/1> ETH=<0/1> FRM=<8hex> DRP=<8hex>\r\n
//
// 用途：上板逐级 debug 时不需要逻辑分析仪就能看到子系统活没活。
//============================================================================
`timescale 1ns/1ps

module acx750_uart_report #(
  parameter int unsigned CLK_HZ    = 100_000_000,
  parameter int unsigned BAUD      = 115_200,
  parameter int unsigned PERIOD_MS = 500
)(
  input  logic        clk,
  input  logic        rst_n,

  input  logic [2:0]  stage,
  input  logic        pll_locked,
  input  logic        ddr3_done,
  input  logic        cam_done,
  input  logic        eth_up,
  input  logic [31:0] frame_cnt,
  input  logic [31:0] drop_cnt,

  output logic        txd
);

  localparam int unsigned PERIOD_CLK = (CLK_HZ / 1000) * PERIOD_MS;
  localparam logic [5:0]  IDX_LAST   = 6'd33;

  function automatic [7:0] hex_ascii(input logic [3:0] n);
    hex_ascii = (n < 4'd10) ? (8'h30 + {4'b0, n}) : (8'h37 + {4'b0, n});
  endfunction

  logic [31:0] period_cnt;
  logic        line_start;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      period_cnt <= '0;
      line_start <= 1'b0;
    end else if (period_cnt == PERIOD_CLK - 1) begin
      period_cnt <= '0;
      line_start <= 1'b1;
    end else begin
      period_cnt <= period_cnt + 1'b1;
      line_start <= 1'b0;
    end
  end

  logic [5:0] idx;
  logic       emitting;
  logic [7:0] byte_out;
  logic [7:0] tx_data_r;   // 关键：待发字节必须与 tx_start 同拍寄存
  logic       tx_start;
  logic       tx_busy;

  always_comb begin
    byte_out = 8'h20;
    case (idx)
      6'd0 : byte_out = "S";
      6'd1 : byte_out = 8'h30 + {5'b0, stage};
      6'd2 : byte_out = " ";
      6'd3 : byte_out = "P";   6'd4 : byte_out = 8'h30 + {7'b0, pll_locked};
      6'd5 : byte_out = "D";   6'd6 : byte_out = 8'h30 + {7'b0, ddr3_done};
      6'd7 : byte_out = "C";   6'd8 : byte_out = 8'h30 + {7'b0, cam_done};
      6'd9 : byte_out = "E";   6'd10: byte_out = 8'h30 + {7'b0, eth_up};
      6'd11: byte_out = " ";
      6'd12: byte_out = "F";
      6'd13: byte_out = hex_ascii(frame_cnt[31:28]);
      6'd14: byte_out = hex_ascii(frame_cnt[27:24]);
      6'd15: byte_out = hex_ascii(frame_cnt[23:20]);
      6'd16: byte_out = hex_ascii(frame_cnt[19:16]);
      6'd17: byte_out = hex_ascii(frame_cnt[15:12]);
      6'd18: byte_out = hex_ascii(frame_cnt[11:8]);
      6'd19: byte_out = hex_ascii(frame_cnt[7:4]);
      6'd20: byte_out = hex_ascii(frame_cnt[3:0]);
      6'd21: byte_out = " ";
      6'd22: byte_out = "X";
      6'd23: byte_out = hex_ascii(drop_cnt[31:28]);
      6'd24: byte_out = hex_ascii(drop_cnt[27:24]);
      6'd25: byte_out = hex_ascii(drop_cnt[23:20]);
      6'd26: byte_out = hex_ascii(drop_cnt[19:16]);
      6'd27: byte_out = hex_ascii(drop_cnt[15:12]);
      6'd28: byte_out = hex_ascii(drop_cnt[11:8]);
      6'd29: byte_out = hex_ascii(drop_cnt[7:4]);
      6'd30: byte_out = hex_ascii(drop_cnt[3:0]);
      6'd31: byte_out = " ";
      6'd32: byte_out = 8'h0D;
      6'd33: byte_out = 8'h0A;
      default: byte_out = 8'h20;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      idx       <= 6'd0;
      emitting  <= 1'b0;
      tx_start  <= 1'b0;
      tx_data_r <= 8'h20;
    end else begin
      tx_start <= 1'b0;
      if (!emitting) begin
        if (line_start) begin
          emitting <= 1'b1;
          idx      <= 6'd0;
        end
      end else if (!tx_busy && !tx_start) begin
        // byte_out 是 idx 的组合函数；tx_start 要到下一拍才被 uart_tx 采到，
        // 所以必须**同拍把字节也寄存下来**，否则下一拍 idx 已经 +1，
        // 实际发出去的是下一个字节——首字节会永久丢失（本模块曾因此少发 S）。
        tx_start  <= 1'b1;
        tx_data_r <= byte_out;
        if (idx == IDX_LAST)
          emitting <= 1'b0;
        else
          idx <= idx + 6'd1;
      end
    end
  end

  acx750_uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
    .clk      (clk),
    .rst_n    (rst_n),
    .tx_start (tx_start),
    .tx_data  (tx_data_r),
    .tx_busy  (tx_busy),
    .txd      (txd)
  );

endmodule