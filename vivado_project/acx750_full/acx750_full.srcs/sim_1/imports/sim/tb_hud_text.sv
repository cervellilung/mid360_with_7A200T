//============================================================================
// tb_hud_text -- HUD 文本展开自检
//
// 例化 acx750_hud_text，把 wr_en/wr_addr/wr_data 写进一个 256x8 的本地数组，
// 等它刷完一整轮（恰好 256 次写：8 行 x 32 列）后逐字节比对：
//   行0 : "ACX750 BRINGUP"（后补空格）
//   行1 : "STG3 P1 D1 C0 E1"
//   行2 : "FRM " + 8 个 hex（对应给定 frame_cnt）
//   行3..6 : RXP/DRP/CAM/PTS + 8 hex
//   行7 : "MID360 AR"
//   其余位置必须为空格 0x20
//
// REFRESH_MS 取 1、CLK_HZ 取 1 MHz，刷新周期仅 1000 个时钟。
// 自检结论：末行打印 "PASS ..." 或 "FAIL ..."。
//============================================================================
`timescale 1ns/1ps

module tb_hud_text;

  localparam int unsigned CLK_HZ     = 1_000_000;
  localparam int unsigned REFRESH_MS = 1;

  localparam logic [2:0]  STAGE_IN = 3'd3;
  localparam logic        PLL_IN   = 1'b1;
  localparam logic        DDR_IN   = 1'b1;
  localparam logic        CAM_IN   = 1'b0;
  localparam logic        ETH_IN   = 1'b1;
  localparam logic [31:0] FRM_IN   = 32'h1A2B3C4D;
  localparam logic [31:0] RXP_IN   = 32'h0000ABCD;
  localparam logic [31:0] DRP_IN   = 32'hDEADBEEF;
  localparam logic [31:0] CAMF_IN  = 32'h00000007;
  localparam logic [31:0] PTS_IN   = 32'h0000FFFF;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic       rst_n = 1'b0;
  logic       wr_en;
  logic [7:0] wr_addr;
  logic [7:0] wr_data;

  logic [7:0] mem [0:255];   // 捕获 HUD RAM 的写入
  logic [7:0] exp [0:255];   // 期望内容
  int         wr_count = 0;
  int         errors   = 0;

  acx750_hud_text #(.CLK_HZ(CLK_HZ), .REFRESH_MS(REFRESH_MS)) dut (
    .clk           (clk),
    .rst_n         (rst_n),
    .stage         (STAGE_IN),
    .pll_locked    (PLL_IN),
    .ddr3_done     (DDR_IN),
    .cam_done      (CAM_IN),
    .eth_up        (ETH_IN),
    .frame_cnt     (FRM_IN),
    .rx_pkt_cnt    (RXP_IN),
    .drop_cnt      (DRP_IN),
    .cam_frame_cnt (CAMF_IN),
    .pts_pkt_cnt   (PTS_IN),
    .wr_en         (wr_en),
    .wr_addr       (wr_addr),
    .wr_data       (wr_data)
  );

  always @(posedge clk) begin
    if (wr_en) begin
      mem[wr_addr] <= wr_data;
      wr_count     = wr_count + 1;
    end
  end

  function automatic logic [7:0] hex_char(input logic [3:0] n);
    hex_char = (n < 4'd10) ? (8'h30 + {4'b0, n}) : (8'h37 + {4'b0, n});
  endfunction

  task automatic check(input bit cond, input string msg);
    if (!cond) begin
      errors = errors + 1;
      $display("FAIL hud_text: %s", msg);
    end
  endtask

  // 把字符串 s 铺到 exp[base ...]，其余保持空格
  task automatic put_str(input int base, input string s);
    int i;
    begin
      for (i = 0; i < s.len(); i = i + 1)
        exp[base+i] = s[i];
    end
  endtask

  // 把 32bit 值的 8 个 hex（大写、高位在前）铺到 exp[base ... base+7]
  task automatic put_hex8(input int base, input logic [31:0] v);
    int i;
    begin
      for (i = 0; i < 8; i = i + 1)
        exp[base+i] = hex_char(v[31 - 4*i -: 4]);
    end
  endtask

  // 逐字节比较 mem[base..base+31] 与 exp[base..base+31]
  task automatic check_row(input int base, input string label);
    int i;
    bit ok;
    begin
      ok = 1'b1;
      for (i = 0; i < 32; i = i + 1) begin
        if (mem[base+i] !== exp[base+i]) begin
          if (ok)
            $display("FAIL hud_text: %s 列%0d 期望 %02x 实际 %02x",
                     label, i, exp[base+i], mem[base+i]);
          ok = 1'b0;
        end
      end
      if (!ok) errors = errors + 1;
    end
  endtask

  integer i;

  initial begin
    for (i = 0; i < 256; i = i + 1) exp[i] = 8'h20;

    put_str(  0, "ACX750 BRINGUP");
    put_str( 32, "STG3 P1 D1 C0 E1");
    put_str( 64, "FRM ");  put_hex8( 68, FRM_IN);
    put_str( 96, "RXP ");  put_hex8(100, RXP_IN);
    put_str(128, "DRP ");  put_hex8(132, DRP_IN);
    put_str(160, "CAM ");  put_hex8(164, CAMF_IN);
    put_str(192, "PTS ");  put_hex8(196, PTS_IN);
    put_str(224, "MID360 AR");

    repeat (4) @(posedge clk);
    rst_n = 1'b1;

    // 刷满一整轮：8 行 x 32 列 = 256 次写
    wait (wr_count >= 256);
    repeat (2) @(posedge clk);

    check(wr_count >= 256, $sformatf("一轮刷新应写 256 次，实际 %0d", wr_count));

    check_row(  0, "第 0 行");
    check_row( 32, "第 1 行");
    check_row( 64, "第 2 行");
    check_row( 96, "第 3 行");
    check_row(128, "第 4 行");
    check_row(160, "第 5 行");
    check_row(192, "第 6 行");
    check_row(224, "第 7 行");

    // 未被模板覆盖的位置必须是空格
    check(mem[14]  === 8'h20, "第 0 行末尾填充应为空格");
    check(mem[255] === 8'h20, "第 7 行末尾填充应为空格");

    if (errors == 0)
      $display("PASS hud_text: 8x32 字符流、动态 hex 字段与空格填充全部正确");
    else
      $display("FAIL hud_text: 共 %0d 处错误", errors);
    $finish;
  end

  initial begin
    #200_000;
    $display("FAIL hud_text: 仿真超时（未刷满一轮）");
    $finish;
  end

endmodule