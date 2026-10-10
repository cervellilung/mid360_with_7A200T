//============================================================================
// acx750_raster_axis -- 「拉取式光栅 → 类 AXIS 视频口」组合适配器
//
// 【背景】
//   ACX750 平台（rtl/acx750_full_top.sv）的显示时序由厂商 disp_driver.v 产生：
//     - 像素钟       : clk_pix（33.333 MHz，= 本模块 pix_clk）
//     - 取数请求     : DataReq（= 平台 disp_req），每个有效像素拉高一拍
//     - 帧首消隐脉冲 : Disp_Sof（= 平台 disp_sof），位于**消隐期**，与第 0 个
//                      有效像素**不重合**
//     - DDR3 读 FIFO : rdfifo_rden = disp_req；rdfifo_dout 就是"该有效的那个
//                      像素数据"，接到本模块 px_data
//   平台顶层在像素域用 px/py 维持光栅坐标（disp_req 推进、disp_sof 清零）。
//
// 【本模块作用（全部组合输出，不打拍）】
//   把"被 disp_req 拉动的光栅"包装成 ar_video / perception_engine 需要的
//   单像素/拍视频口（s_data/s_valid/s_sof/s_eol）：
//     video_valid = disp_req                                  // 有有效像素
//     video_sof   = disp_req && px==0 && py==0               // 帧首**有效像素**
//     video_eol   = disp_req && px==799                      // 行尾有效像素
//     video_data  = px_data                                  // RGB565 直通
//
// 【关键点】**不要**用 disp_sof 当 video_sof：
//   disp_sof 是垂直同步沿产生的消隐期脉冲（disp_driver 里由 Disp_VS 上升沿
//   得到），它与第一个有效像素不在同一拍。ar_video 用 s_sof 复位内部坐标
//   (px,py) 并触发配置交换，必须落在**第一个有效像素**上，所以这里用
//   (px==0 && py==0) 判定，与 disp_req 相与。
//
// 【延迟】本模块为纯组合，0 拍；ar_video 的 s→m 寄存器延迟为 1 拍（见
//   docs/video_pipeline_750.md）。
//
// 【未用输入】pix_clk / pix_rst_n / disp_sof 故意保留在端口上以便将来加探针
//   或改寄存输出时不改接口；当前实现不引用它们（综合仅产生未用告警）。
//============================================================================
`timescale 1ns/1ps

module acx750_raster_axis (
  input  logic        pix_clk,     // 像素时钟（本模块不用，仅为接口一致）
  input  logic        pix_rst_n,   // 像素域复位，低有效（本模块不用）
  input  logic        disp_req,    // == disp_driver.DataReq
  input  logic        disp_sof,    // == disp_driver.Disp_Sof（消隐期脉冲，不用）
  input  logic [11:0] px, py,      // 光栅坐标（已由顶层在 disp_req 上维护）
  input  logic [15:0] px_data,     // 帧缓存读出的 RGB565（与 disp_req 同拍）
  output logic [15:0] video_data,
  output logic        video_valid,
  output logic        video_sof,
  output logic        video_eol
);

  // px==799 / py==0 直接用常量（与 acx750_defs.svh 的 DISP_WIDTH/DISP_HEIGHT 一致）
  assign video_valid = disp_req;
  assign video_sof   = disp_req && (px == 12'd0) && (py == 12'd0);
  assign video_eol   = disp_req && (px == 12'd799);
  assign video_data  = px_data;

endmodule