//============================================================================
// acx750_hud_ram -- HUD 文本缓冲：256 x 8bit 简单双端口 BRAM
//
// 写口在系统时钟域（acx750_hud_text 逐字符刷新），读口在像素时钟域
// （acx750_hud 按扫描坐标取字符）。两个时钟域各自独立，属于最简单的
// 双时钟简单双端口 RAM 模板，Vivado 会推断成一块 RAMB18/36。
//
// 上电初始化为空格，避免刷新前显示随机花纹。
//============================================================================
`timescale 1ns/1ps

module acx750_hud_ram (
  input  logic       wr_clk,
  input  logic       wr_en,
  input  logic [7:0] wr_addr,
  input  logic [7:0] wr_data,

  input  logic       rd_clk,
  input  logic [7:0] rd_addr,
  output logic [7:0] rd_data
);

  (* ram_style = "block" *) logic [7:0] mem [0:255];

  integer i;
  initial begin
    for (i = 0; i < 256; i = i + 1)
      mem[i] = 8'h20;                 // 空格
  end

  always_ff @(posedge wr_clk) begin
    if (wr_en)
      mem[wr_addr] <= wr_data;
  end

  always_ff @(posedge rd_clk) begin
    rd_data <= mem[rd_addr];
  end

endmodule