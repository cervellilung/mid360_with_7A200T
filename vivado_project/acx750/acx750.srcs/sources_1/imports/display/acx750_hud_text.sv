//============================================================================
// acx750_hud_text -- HUD 文本生成（系统时钟域）
//
// 走一张模板表 TPL，把静态字符与动态字段拼成 8 行 x 32 列的字符，
// 逐字节写进 acx750_hud_ram。
//
// 模板里的控制码：
//   8'h0A = 换行：本行剩余位置填空格，行号 +1
//   8'h00 = 取 hex 流的下一个 4bit，输出 0-9/A-F
//   8'h01 = 取 flag 流的下一个 4bit，输出 0-7
// 其余字节原样输出。
//
// 显示的 8 行内容（列 0 起）：
//   ACX750 BRINGUP
//   STG? P? D? C? E?
//   FRM ????????
//   RXP ????????
//   DRP ????????
//   CAM ????????
//   PTS ????????
//   MID360 AR
//============================================================================
`timescale 1ns/1ps

module acx750_hud_text #(
  parameter int unsigned CLK_HZ     = 100_000_000,
  parameter int unsigned REFRESH_MS = 250
)(
  input  logic        clk,
  input  logic        rst_n,

  input  logic [2:0]  stage,
  input  logic        pll_locked,
  input  logic        ddr3_done,
  input  logic        cam_done,
  input  logic        eth_up,

  input  logic [31:0] frame_cnt,      // FRM
  input  logic [31:0] rx_pkt_cnt,     // RXP
  input  logic [31:0] drop_cnt,       // DRP
  input  logic [31:0] cam_frame_cnt,  // CAM
  input  logic [31:0] pts_pkt_cnt,    // PTS

  output logic        wr_en,
  output logic [7:0]  wr_addr,
  output logic [7:0]  wr_data
);

  localparam int unsigned REFRESH_CLK = (CLK_HZ / 1000) * REFRESH_MS;

  //--------------------------------------------------------------------
  // 模板表（每行 32 列，换行码 8'h0A）
  //--------------------------------------------------------------------
  // 实际用到 0..108（第 7 行结束）。数组长度必须与初始值个数**完全一致**
// （SystemVerilog 的赋值模式不允许长度不匹配，xelab 会报 VRFC 10-666）。
  localparam logic [7:0] TPL [0:108] = '{
    // 行 0
    "A","C","X","7","5","0"," ","B","R","I","N","G","U","P", 8'h0A,
    // 行 1：STG? P? D? C? E?
    "S","T","G", 8'h01, " ","P", 8'h01, " ","D", 8'h01,
    " ","C", 8'h01, " ","E", 8'h01, 8'h0A,
    // 行 2：FRM ????????
    "F","R","M"," ", 8'h00, 8'h00, 8'h00, 8'h00,
                     8'h00, 8'h00, 8'h00, 8'h00, 8'h0A,
    // 行 3：RXP ????????
    "R","X","P"," ", 8'h00, 8'h00, 8'h00, 8'h00,
                     8'h00, 8'h00, 8'h00, 8'h00, 8'h0A,
    // 行 4：DRP ????????
    "D","R","P"," ", 8'h00, 8'h00, 8'h00, 8'h00,
                     8'h00, 8'h00, 8'h00, 8'h00, 8'h0A,
    // 行 5：CAM ????????
    "C","A","M"," ", 8'h00, 8'h00, 8'h00, 8'h00,
                     8'h00, 8'h00, 8'h00, 8'h00, 8'h0A,
    // 行 6：PTS ????????
    "P","T","S"," ", 8'h00, 8'h00, 8'h00, 8'h00,
                     8'h00, 8'h00, 8'h00, 8'h00, 8'h0A,
    // 行 7
    "M","I","D","3","6","0"," ","A","R",
    8'h0A,
    // 补齐（不会被执行到）
    8'h0A, 8'h0A
  };

  localparam logic [2:0] S_IDLE = 3'd0, S_CHAR = 3'd1, S_PAD = 3'd2;

  function automatic [7:0] hex_ascii(input logic [3:0] n);
    hex_ascii = (n < 4'd10) ? (8'h30 + {4'b0, n}) : (8'h37 + {4'b0, n});
  endfunction

  logic [31:0] refresh_cnt;
  logic        start;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      refresh_cnt <= '0;
      start       <= 1'b0;
    end else if (refresh_cnt == REFRESH_CLK - 1) begin
      refresh_cnt <= '0;
      start       <= 1'b1;
    end else begin
      refresh_cnt <= refresh_cnt + 1'b1;
      start       <= 1'b0;
    end
  end

  logic [7:0]   tpl_idx;
  logic [2:0]   row;
  logic [4:0]   col;
  logic [2:0]   state;
  logic [159:0] hex_stream;
  logic [19:0]  flag_stream;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_en       <= 1'b0;
      wr_addr     <= 8'h00;
      wr_data     <= 8'h20;
      tpl_idx     <= 8'h00;
      row         <= 3'd0;
      col         <= 5'd0;
      state       <= S_IDLE;
      hex_stream  <= '0;
      flag_stream <= '0;
    end else begin
      wr_en <= 1'b0;

      case (state)
        S_IDLE: begin
          if (start) begin
            hex_stream  <= {frame_cnt, rx_pkt_cnt, drop_cnt, cam_frame_cnt, pts_pkt_cnt};
            flag_stream <= {1'b0, stage,
                            3'b0, pll_locked,
                            3'b0, ddr3_done,
                            3'b0, cam_done,
                            3'b0, eth_up};
            tpl_idx <= 8'd0;
            row     <= 3'd0;
            col     <= 5'd0;
            state   <= S_CHAR;
          end
        end

        S_CHAR: begin
          if (TPL[tpl_idx] == 8'h0A) begin
            // 换行：本行没写满就补空格
            if (col == 5'd31) begin
              col     <= 5'd0;
              tpl_idx <= tpl_idx + 8'd1;
              if (row == 3'd7) state <= S_IDLE;
              else             row   <= row + 3'd1;
            end else begin
              state <= S_PAD;
            end
          end else begin
            wr_en   <= 1'b1;
            wr_addr <= {row, col};
            unique case (TPL[tpl_idx])
              8'h00: begin
                wr_data    <= hex_ascii(hex_stream[159:156]);
                hex_stream <= {hex_stream[155:0], 4'h0};
              end
              8'h01: begin
                wr_data     <= 8'h30 + {4'b0, flag_stream[19:16]};
                flag_stream <= {flag_stream[15:0], 4'h0};
              end
              default: wr_data <= TPL[tpl_idx];
            endcase
            tpl_idx <= tpl_idx + 8'd1;
            if (col == 5'd31) begin
              col <= 5'd0;
              if (row == 3'd7) state <= S_IDLE;
              else             row   <= row + 3'd1;
            end else begin
              col <= col + 5'd1;
            end
          end
        end

        S_PAD: begin
          wr_en   <= 1'b1;
          wr_addr <= {row, col};
          wr_data <= 8'h20;
          if (col == 5'd31) begin
            col     <= 5'd0;
            tpl_idx <= tpl_idx + 8'd1;
            if (row == 3'd7) state <= S_IDLE;
            else begin
              row   <= row + 3'd1;
              state <= S_CHAR;
            end
          end else begin
            col <= col + 5'd1;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule