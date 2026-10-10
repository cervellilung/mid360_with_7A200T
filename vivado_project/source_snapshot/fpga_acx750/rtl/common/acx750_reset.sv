//============================================================================
// acx750_reset -- 上电/按键复位同步与展宽
//
// 行为：
//   1. 按键输入异步去抖（低有效）
//   2. 只有当 PLL/MMCM locked 为高，并且按键释放后计数器溢出，才放开复位
//   3. 输出的 rst_n 与 clk 同步，且释放是单周期干净的（异步置位/同步释放）
//
// 注意：不要把 MIG 的 init_calib_complete 并进来。DDR3 校准未完成时 MIG
// 自己的复位域由 ddr3_ctrl_2port 处理，全局复位跟着它走会造成校准死锁。
//============================================================================
`timescale 1ns/1ps

module acx750_reset #(
  parameter int unsigned DEBOUNCE_CLK = 1_000_000   // 按键去抖/展宽计数（10 ms @100 MHz）
)(
  input  logic clk,            // 系统时钟
  input  logic locked,         // MMCM locked
  input  logic btn_reset_n,    // 按键复位，低有效，异步
  output logic rst_n           // 同步后低有效复位
);

  // 按键输入打两拍，消除亚稳态
  (* ASYNC_REG = "TRUE" *) logic [2:0] btn_sync;
  always_ff @(posedge clk) begin
    btn_sync <= {btn_sync[1:0], btn_reset_n};
  end
  wire btn_n = btn_sync[2];

  // 计数：只有 locked 且按键释放后才开始累加
  logic [23:0] cnt;
  logic        hold;
  always_ff @(posedge clk) begin
    if (!locked || !btn_n) begin
      cnt  <= '0;
      hold <= 1'b1;
    end else if (cnt < DEBOUNCE_CLK[23:0]) begin
      cnt  <= cnt + 1'b1;
      hold <= 1'b1;
    end else begin
      hold <= 1'b0;
    end
  end

  // 异步置位、同步释放
  (* ASYNC_REG = "TRUE" *) logic [1:0] rst_sync;
  always_ff @(posedge clk or negedge btn_n) begin
    if (!btn_n)
      rst_sync <= 2'b00;
    else
      rst_sync <= {rst_sync[0], ~hold};
  end

  assign rst_n = rst_sync[1];

endmodule