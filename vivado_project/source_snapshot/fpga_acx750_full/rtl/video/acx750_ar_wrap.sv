//============================================================================
// acx750_ar_wrap -- 感知/AR 视频流水的一层干净包装
//
// TODO(750): 依赖 rtl/perception/*（perception_engine.sv 及其例化的
//            ar_video / fixed_projector / lidar_grid / mid360_points /
//            chassis_motion / packet_tap / cell_ram / integer_math、
//            以及头文件 perception_types.svh）。
//            这些文件由另一路 agent 从 fpga_ac880 原样搬入 rtl/perception/，
//            行为零改动；本文件不改动它们。文件到位后本模块可直接编译。
//
// 【数据流】
//   控制域(clk)  : now_us / radar_* / odom_* / cfg / lut ... → perception_engine
//   像素域(pix_clk): disp_req + px/py + px_data
//        │
//        ├─ acx750_raster_axis : 光栅 → video_data/valid/sof/eol（组合，0 拍）
//        │
//        └─ perception_engine（内含 ar_video）：
//               s 口 ← raster 适配器；m 口 → disp_out（s→m 寄存器延迟 = 1 拍）
//
// 【对齐】out_ready 恒 1（显示不能反压）；disp_out = out_data（组合，不打拍），
//   直接接厂商 disp_driver.Data。s→m 延迟实测为 1 拍，与 disp_driver 的
//   AHEAD_CLK_CNT=2 所要求的"Data 比 DataReq 晚 1 拍"一致，顶层无需补偿；
//   依据与推导见 docs/video_pipeline_750.md。
//
// 【复位极性】perception_engine / ar_video 的 rst 为**高有效**，而本包装对外
//   用低有效 rst_n / pix_rst_n，故内部取反后再接。
//
// 【VIDEO_HZ / COMPACT_HUD】
//   ar_video 的 VIDEO_HZ 只被 perception_engine 内部例化时使用（未参数化）；
//   它仅影响 HUD 的"年龄/过期"时基（next_age=(age_us)*(VIDEO_HZ/1e6) 与
//   live=age<(VIDEO_HZ/1e3)*150），**不影响像素对齐**。750 像素钟若按
//   33.333 MHz，正确取值应为 33_333_333（VIDEO_HZ/1e6 必须整除得 33）。
//   由于本文件不得修改 rtl/perception/*，这里无法覆盖该参数；如需生效，
//   需由感知核负责人给 perception_engine 增加参数或在 ar_video 内改默认值。
//   现网元实际使用 ar_video 默认值 200_000_000，后果见 docs/video_pipeline_750.md。
//============================================================================
`timescale 1ns/1ps

module acx750_ar_wrap (
  // ---- 控制域（clk）----
  input  logic          clk,
  input  logic          rst_n,
  input  logic [63:0]   now_us,
  input  logic [7:0]    radar_data,
  input  logic          radar_valid,
  input  logic          radar_last,
  input  logic [7:0]    odom_data,
  input  logic          odom_valid,
  input  logic          odom_last,
  input  logic [31:0]   src_fifo_overflow,
  input  logic [31:0]   src_eth_rejected,
  input  logic [31:0]   src_odom_bad,
  input  logic [31:0]   src_odom_busy,
  input  logic [31:0]   src_radar_slot_drops,
  input  logic [31:0]   src_chassis_slot_drops,
  input  logic [2047:0] cfg,
  input  logic [7071:0] lut,
  input  logic          cfg_pending,
  output logic          cfg_safe,
  output logic          snapshot_start,
  output logic [1023:0] metadata,
  input  logic [4:0]    snapshot_index,
  input  logic          snapshot_busy,
  output logic [383:0]  snapshot_object,
  // 栅格只读口（M3TL type=5 遥测用）：透传到 perception_engine → lidar_grid。
  // 方向与 perception_engine 侧一致：addr 由读方驱动（input），data 为只读输出。
  // 位宽暂用 [11:0]（55*60=3300 需 12 位），待 docs/sensor_datalane_750.md
  // 定稿后与 perception_engine 实际位宽核对（见报告「待确认项」）。
  input  logic [11:0]   grid_rd_addr,
  output logic [7:0]    grid_rd_data,

  // ---- 像素域（pix_clk）----
  input  logic          pix_clk,
  input  logic          pix_rst_n,
  input  logic          disp_req,
  input  logic          disp_sof,
  input  logic [11:0]   px,
  input  logic [11:0]   py,
  input  logic [15:0]   px_data,

  // ---- 显示数据输出（组合，接 disp_driver.Data）----
  output logic [15:0]   disp_out,

  // ---- 调试 ----
  output logic          video_ready
);

  // 光栅适配器输出（= perception_engine 的 s 口）
  logic [15:0] v_data;
  logic        v_valid, v_sof, v_eol;

  // perception_engine 的 m 口
  logic [15:0] o_data;
  logic        o_valid, o_sof, o_eol;

  //--------------------------------------------------------------------------
  // 1) 光栅 → 视频口（纯组合，0 拍）
  //--------------------------------------------------------------------------
  acx750_raster_axis u_raster (
    .pix_clk    (pix_clk),
    .pix_rst_n  (pix_rst_n),
    .disp_req   (disp_req),
    .disp_sof   (disp_sof),
    .px         (px),
    .py         (py),
    .px_data    (px_data),
    .video_data (v_data),
    .video_valid(v_valid),
    .video_sof  (v_sof),
    .video_eol  (v_eol)
  );

  //--------------------------------------------------------------------------
  // 2) 感知核（含 ar_video 叠加 + HUD），控制域 clk / 像素域 pix_clk
  //    注意：rst 为高有效，这里取反。
  //--------------------------------------------------------------------------
  perception_engine u_engine (
    .clk                     (clk),
    .rst                     (~rst_n),
    .now_us                  (now_us),
    .radar_data              (radar_data),
    .radar_valid             (radar_valid),
    .radar_last              (radar_last),
    .odom_data               (odom_data),
    .odom_valid              (odom_valid),
    .odom_last               (odom_last),
    .source_fifo_overflow    (src_fifo_overflow),
    .source_eth_rejected     (src_eth_rejected),
    .source_odom_bad         (src_odom_bad),
    .source_odom_busy        (src_odom_busy),
    .source_radar_slot_drops (src_radar_slot_drops),
    .source_chassis_slot_drops(src_chassis_slot_drops),
    .cfg                     (cfg),
    .lut                     (lut),
    .cfg_pending             (cfg_pending),
    .cfg_safe                (cfg_safe),
    .snapshot_start          (snapshot_start),
    .metadata                (metadata),
    .snapshot_index          (snapshot_index),
    .snapshot_busy           (snapshot_busy),
    .snapshot_object         (snapshot_object),
    // 栅格只读口（待 perception_engine 落口后即可编译；见文件头 TODO(750)）
    .grid_rd_addr            (grid_rd_addr),
    .grid_rd_data            (grid_rd_data),
    .video_clk               (pix_clk),
    .video_rst               (~pix_rst_n),
    .video_data              (v_data),
    .video_valid             (v_valid),
    .video_sof               (v_sof),
    .video_eol               (v_eol),
    .video_ready             (video_ready),
    .out_data                (o_data),
    .out_valid               (o_valid),
    .out_sof                 (o_sof),
    .out_eol                 (o_eol),
    .out_ready               (1'b1)          // 显示不能反压：m 侧恒 ready
  );

  //--------------------------------------------------------------------------
  // 3) 显示数据：组合直通，不打拍
  //--------------------------------------------------------------------------
  assign disp_out = o_data;

endmodule