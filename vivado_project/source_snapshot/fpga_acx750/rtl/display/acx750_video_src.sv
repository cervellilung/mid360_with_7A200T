//============================================================================
// acx750_video_src -- 像素源 / 显示时序衔接 / 彩条测试图 / HUD 顶层
//
// 与厂商 disp_driver(AHEAD_CLK_CNT=1) 的握手对齐关系（关键，勿改）：
//   disp_driver 在 n 拍给出 DataReq（reg），并在 n+1 拍用 Disp_DE_pre 把
//   当时的 Data 打进 RGB 寄存器。也就是说：
//       DataReq 在 n 拍  ->  Data 必须在 n+1 拍有效。
//   DataReq 是"按光栅顺序取下一個像素"的请求脉冲，每帧 800x480 个，顺序为
//   从左到右、从上到下；因此本模块在 req 当拍用坐标计数器给出的 (x,y)
//   就是"本拍正在请求的像素坐标"。
//
//   统一的一拍流水对齐（三种底色在同一条流水线上）：
//       第 n   拍：req=1，(x,y)=X；彩条用 X 组合算出颜色 -> 打一拍进 cbar_q
//       第 n+1 拍：cbar_q = X 处颜色；fb_dout/cam_dout 本来就是"上一拍请求
//                 的像素"（已在 DDR3 读口对齐），base_sel 组合选出 X 处底色
//       HUD 也工作在同一节拍：en=req(n)，x,y=X(n)，HUD 内部把 (x,y) 打一拍
//       得到 (dx,dy)，所以它在 n+1 拍取用 base（此时 base_sel 正是 X 处底色）
//       与文本读回数据，二者对齐。
//       最后 data = hud_on ? hud_rgb : base_sel 必须组合输出(第 n+1 拍有效)，
//       绝不能再打一拍，否则会晚一拍、与 RGB 寄存器错位。
//============================================================================
`timescale 1ns/1ps

`include "../acx750_defs.svh"

module acx750_video_src (
  input  logic        pix_clk,        // 33 MHz 像素钟
  input  logic        pix_rst_n,      // 同步到 pix_clk 的低有效复位
  input  logic        req,            // == disp_driver.DataReq
  input  logic        sof,            // == disp_driver.Disp_Sof
  input  logic [2:0]  stage,          // 已同步到 pix_clk 的阶段号
  // 帧缓存读出（DDR3 双端口控制器的读 FIFO 输出）
  input  logic [15:0] fb_dout,        // 已经与 req 对齐：本拍的值就是 req 上一拍请求的像素
  // 摄像头帧缓存读出（同一块 DDR3，另一路读口；本轮先用同一接口占位）
  input  logic [15:0] cam_dout,       // 同上对齐关系
  // HUD 文本缓冲读口（转发给 acx750_hud）
  output logic [7:0]  hud_txt_addr,
  input  logic [7:0]  hud_txt_data,
  // 给 disp_driver.Data（组合输出，必须在 req 的下一拍有效）
  output logic [15:0] data
);

  //==========================================================================
  // 1) 像素坐标计数器
  //    在 req 当拍推进，req 给出的是"当前请求像素"的坐标；sof 清零。
  //==========================================================================
  localparam logic [11:0] X_LAST = `DISP_WIDTH  - 1;   // 799
  localparam logic [11:0] Y_LAST = `DISP_HEIGHT - 1;   // 479

  logic [11:0] x, y;

  always_ff @(posedge pix_clk or negedge pix_rst_n) begin
    if (!pix_rst_n) begin
      x <= 12'd0;
      y <= 12'd0;
    end else if (sof) begin
      x <= 12'd0;
      y <= 12'd0;
    end else if (req) begin
      if (x >= X_LAST) begin
        x <= 12'd0;
        if (y >= Y_LAST)
          y <= 12'd0;
        else
          y <= y + 12'd1;
      end else begin
        x <= x + 12'd1;
      end
    end
  end

  //==========================================================================
  // 2) 彩条测试图发生器（组合算颜色，随后打一拍，供 req 的下一拍使用）
  //    分工：
  //      y <  360 : 8 条标准彩条，每条 100 像素宽
  //      360..419 : 32 级灰阶阶梯，每级 25 像素宽
  //      420..439 : 32 级 红->绿->蓝 过渡色带，每级 25 像素宽
  //      y >= 440 : 黑底 + 从左到右逐渐变长的白色进度条（确认整帧在刷新）
  //      最外圈 2 像素白边框
  //==========================================================================
  localparam logic [11:0] Y_BARS_END = 12'd360;
  localparam logic [11:0] Y_GRAY_END = 12'd420;
  localparam logic [11:0] Y_BAND_END = 12'd440;

  // 用乘加代替除法，避免综合出除法器：
  //   x/100 ~= (x*41)  >> 12 ； x/25 ~= (x*164) >> 12
  wire [17:0] xm100   = x * 18'd41;
  wire [17:0] xm25    = x * 18'd164;
  wire [5:0]  idx100  = xm100[17:12];   // 0..7  彩条序号
  wire [5:0]  idx25   = xm25[17:12];    // 0..31 灰阶/过渡级数
  wire [2:0]  bar_sel = idx100[2:0];
  wire [4:0]  gray5   = idx25[4:0];     // 0..31 5 位灰阶

  // 灰阶：R=B=gray5(5bit)；G 用"复制最高位"扩展到 6bit，保证 r=g=b 中性灰
  wire [15:0] gray_rgb = { gray5[4:0], gray5[4:0], gray5[4], gray5[4:0] };

  // 红->绿->蓝 过渡：0..15 红->绿，16..31 绿->蓝；R/B 5bit，G 同样复制最高位
  logic [4:0] band_r, band_g, band_b;
  wire [4:0]  ramp = { idx25[3:0], 1'b0 };   // 0,2,..,30
  always_comb begin
    if (idx25[4]) begin
      band_r = 5'd0;
      band_g = 5'd31 - ramp;
      band_b = ramp;
    end else begin
      band_r = 5'd31 - ramp;
      band_g = ramp;
      band_b = 5'd0;
    end
  end
  wire [15:0] band_rgb = { band_r[4:0], band_g[4:0], band_g[4], band_b[4:0] };

  // 进度条长度：随行号增长，形成从左到右的斜坡，便于确认整帧刷新
  wire [11:0] prog_len = (y >= Y_BAND_END) ? ((y - Y_BAND_END) * 12'd20) : 12'd0;

  logic [15:0] cbar_comb;
  always_comb begin
    cbar_comb = 16'h0000;
    if (y < Y_BARS_END) begin
      case (bar_sel)
        3'd0:    cbar_comb = 16'hFFFF;   // 白
        3'd1:    cbar_comb = 16'hFFE0;   // 黄
        3'd2:    cbar_comb = 16'h07FF;   // 青
        3'd3:    cbar_comb = 16'h07E0;   // 绿
        3'd4:    cbar_comb = 16'hF81F;   // 品红
        3'd5:    cbar_comb = 16'hF800;   // 红
        3'd6:    cbar_comb = 16'h001F;   // 蓝
        default: cbar_comb = 16'h0000;   // 黑
      endcase
    end else if (y < Y_GRAY_END) begin
      cbar_comb = gray_rgb;
    end else if (y < Y_BAND_END) begin
      cbar_comb = band_rgb;
    end else begin
      cbar_comb = (x < prog_len) ? 16'hFFFF : 16'h0000;
    end
    // 最外圈 2 像素白边框（覆盖以上所有图案）
    if (x < 12'd2 || x > 12'd797 || y < 12'd2 || y > 12'd477)
      cbar_comb = 16'hFFFF;
  end

  // 关键：彩条算完打一拍。第 n 拍用 (x,y)=X 算出颜色，第 n+1 拍 cbar_q 即为
  // X 处底色，正好满足 disp_driver 对 Data 的"下一拍有效"要求。
  logic [15:0] cbar_q;
  always_ff @(posedge pix_clk or negedge pix_rst_n) begin
    if (!pix_rst_n)
      cbar_q <= 16'h0000;
    else
      cbar_q <= cbar_comb;
  end

  //==========================================================================
  // 3) 三路底色选择（组合，用 stage 选）
  //    cbar_q(彩条，上一拍算好) 与 fb_dout/cam_dout(本拍已有效) 同一拍可用，
  //    因此这一级组合选择是正确的。
  //==========================================================================
  logic [15:0] base_sel;
  always_comb begin
    case (stage)
      `STAGE_CAMERA:    base_sel = cam_dout;
      `STAGE_ETH_IMAGE,
      `STAGE_DDR3_SELF,
      `STAGE_AR,
      `STAGE_TELEM,
      `STAGE_SPLIT:     base_sel = fb_dout;
      default:          base_sel = cbar_q;   // STAGE_COLORBAR / STAGE_HUD_DEMO
    endcase
  end

  //==========================================================================
  // 4) HUD 例化 + 最终组合输出
  //    en=req、x,y=当前请求坐标；HUD 内部把坐标打一拍，正好在下一拍与
  //    base(即 base_sel) 和文本读回数据对齐。data 必须组合输出。
  //==========================================================================
  logic        hud_on;
  logic [15:0] hud_rgb;

  acx750_hud u_hud (
    .pix_clk    (pix_clk),
    .pix_rst_n  (pix_rst_n),
    .en         (req),
    .x          (x),
    .y          (y),
    .txt_addr   (hud_txt_addr),
    .txt_data   (hud_txt_data),
    .base       (base_sel),
    .hud_on     (hud_on),
    .hud_rgb    (hud_rgb)
  );

  assign data = hud_on ? hud_rgb : base_sel;

endmodule