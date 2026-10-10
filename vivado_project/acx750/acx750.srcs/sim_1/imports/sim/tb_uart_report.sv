//============================================================================
// tb_uart_report -- 周期状态行自检
//
// 把 acx750_uart_report 的 txd 接回 acx750_uart_rx，收一行 34 字节，校验：
//   * 共 34 字节、以 'S' 开头、以 CR/LF 结尾
//   * 整行逐字节等于按输入拼出的期望
//   * 'F' / 'X' 后面的 8 个 hex 与 frame_cnt / drop_cnt 一致
//
// PERIOD_MS=1、CLK_HZ=1 MHz、BAUD=100 kHz，一行 34 字节约 3.4k 周期。
// 自检结论：末行打印 "PASS ..." 或 "FAIL ..."。
//============================================================================
`timescale 1ns/1ps

module tb_uart_report;

  localparam int unsigned CLK_HZ    = 1_000_000;
  localparam int unsigned BAUD      = 100_000;
  localparam int unsigned PERIOD_MS = 1;

  localparam logic [2:0]  STAGE_IN = 3'd1;
  localparam logic        PLL_IN   = 1'b1;
  localparam logic        DDR_IN   = 1'b1;
  localparam logic        CAM_IN   = 1'b0;
  localparam logic        ETH_IN   = 1'b1;
  localparam logic [31:0] FRM_IN   = 32'h000000A5;
  localparam logic [31:0] DRP_IN   = 32'hDEADBEEF;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic       rst_n = 1'b0;
  logic       txd;
  logic [7:0] rx_data;
  logic       rx_valid;

  logic [7:0] line [0:63];
  logic [7:0] want [0:33];
  int         got    = 0;
  int         errors = 0;

  acx750_uart_report #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .PERIOD_MS(PERIOD_MS)) dut (
    .clk        (clk),
    .rst_n      (rst_n),
    .stage      (STAGE_IN),
    .pll_locked (PLL_IN),
    .ddr3_done  (DDR_IN),
    .cam_done   (CAM_IN),
    .eth_up     (ETH_IN),
    .frame_cnt  (FRM_IN),
    .drop_cnt   (DRP_IN),
    .txd        (txd)
  );

  acx750_uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_rx (
    .clk           (clk),
    .rst_n         (rst_n),
    .rxd           (txd),
    .rx_data       (rx_data),
    .rx_data_valid (rx_valid)
  );

  always @(posedge clk) begin
    if (rx_valid && got < 64) begin
      line[got] = rx_data;
      got       = got + 1;
    end
  end

  // 大写 hex 字符（与 RTL 的 hex_ascii 约定一致：10..15 -> 'A'..'F'）
  function automatic logic [7:0] hex_char(input logic [3:0] n);
    hex_char = (n < 4'd10) ? (8'h30 + {4'b0, n}) : (8'h37 + {4'b0, n});
  endfunction

  function automatic logic [3:0] ascii_hex(input logic [7:0] c);
    if (c >= 8'h30 && c <= 8'h39)      ascii_hex = c - 8'h30;
    else if (c >= 8'h41 && c <= 8'h46) ascii_hex = c - 8'h41 + 4'd10;
    else                                ascii_hex = 4'hF;
  endfunction

  function automatic logic [31:0] hex8_to_u32(input int base);
    int i;
    begin
      hex8_to_u32 = 32'd0;
      for (i = 0; i < 8; i = i + 1)
        hex8_to_u32 = {hex8_to_u32[27:0], ascii_hex(line[base+i])};
    end
  endfunction

  task automatic check(input bit cond, input string msg);
    if (!cond) begin
      errors = errors + 1;
      $display("FAIL uart_report: %s", msg);
    end
  endtask

  task automatic build_expect();
    int i;
    begin
      // "S<stage> P<pll>D<ddr>C<cam>E<eth> F<frame8> X<drop8> \r\n" 共 34 字节
      want[ 0] = 8'h53;                                   // 'S'
      want[ 1] = 8'h30 + {5'b0, STAGE_IN};                // 阶段号
      want[ 2] = 8'h20;
      want[ 3] = 8'h50;  want[ 4] = 8'h30 + {7'b0, PLL_IN}; // 'P'
      want[ 5] = 8'h44;  want[ 6] = 8'h30 + {7'b0, DDR_IN}; // 'D'
      want[ 7] = 8'h43;  want[ 8] = 8'h30 + {7'b0, CAM_IN}; // 'C'
      want[ 9] = 8'h45;  want[10] = 8'h30 + {7'b0, ETH_IN}; // 'E'
      want[11] = 8'h20;
      want[12] = 8'h46;                                   // 'F'
      for (i = 0; i < 8; i = i + 1)
        want[13+i] = hex_char(FRM_IN[31 - 4*i -: 4]);
      want[21] = 8'h20;
      want[22] = 8'h58;                                   // 'X'
      for (i = 0; i < 8; i = i + 1)
        want[23+i] = hex_char(DRP_IN[31 - 4*i -: 4]);
      want[31] = 8'h20;
      want[32] = 8'h0D;
      want[33] = 8'h0A;
    end
  endtask

  integer i;

  initial begin
    build_expect();

    repeat (6) @(posedge clk);
    rst_n = 1'b1;

    wait (got >= 34);
    repeat (4) @(posedge clk);

    check(got >= 34, $sformatf("未收到完整一行，实际 %0d 字节", got));

    if (got >= 34) begin
      check(line[ 0] === 8'h53, $sformatf("整行应以 'S' 开头，实际 0x%02x", line[0]));
      check(line[32] === 8'h0D, $sformatf("倒数第 2 字节应为 CR，实际 0x%02x", line[32]));
      check(line[33] === 8'h0A, $sformatf("末字节应为 LF，实际 0x%02x", line[33]));

      for (i = 0; i < 34; i = i + 1) begin
        if (line[i] !== want[i]) begin
          errors = errors + 1;
          $display("FAIL uart_report: 第 %0d 字节 期望 0x%02x 实际 0x%02x",
                   i, want[i], line[i]);
        end
      end

      // 'F' / 'X' 字段单独再查一次
      check(line[12] === 8'h46, "'F' 字段位置不正确");
      check(line[22] === 8'h58, "'X' 字段位置不正确");
      check(hex8_to_u32(13) === FRM_IN,
            $sformatf("F 后 hex 应为 %08x，实际 %08x", FRM_IN, hex8_to_u32(13)));
      check(hex8_to_u32(23) === DRP_IN,
            $sformatf("X 后 hex 应为 %08x，实际 %08x", DRP_IN, hex8_to_u32(23)));
    end

    if (errors == 0)
      $display("PASS uart_report: 34 字节状态行以 S 开头，F/X 十六进制与输入一致");
    else
      $display("FAIL uart_report: 共 %0d 处错误", errors);
    $finish;
  end

  initial begin
    #500_000;
    $display("FAIL uart_report: 仿真超时");
    $finish;
  end

endmodule