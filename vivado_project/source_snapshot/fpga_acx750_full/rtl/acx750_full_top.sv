//============================================================================
// acx750_full_top -- ACX750 (XC7A200T-FBG484-2) 集成整机顶层
//
// 【本工程定位】
//   fpga_acx750/        = 纯平台基线（无感知核），已验证到「综合通过(IP 桩)」
//   fpga_acx750_full/   = 本工程：在平台之上**把 XC7Z020 侧的感知/AR 全部搬进来**
//
// 相对基线的**新增**部分（本文件里用 `INTEG-750` 注释块标出接入点）：
//   1. rtl/perception/  —— 从 fpga_ac880/sensor_perception_ar/rtl/ 原样搬入的感知核
//                          （lidar_grid / perception_engine / fixed_projector /
//                            ar_video / mid360_points / chassis_motion / packet_tap …）
//   2. rtl/video/       —— 新增的「DDR3 帧缓存 ⇄ AXI-Stream 视频流」读写引擎
//                          （7020 上这部分由 PS + VDMA 承担，750 上必须自己写）
//   3. rtl/eth/         —— 新增控制面：UDP 下行配置 → 寄存器组（替代 PS 的 AXI-Lite
//                          perception_regs），以及 M3TL type=3/5 遥测（目标/栅格）
//   4. 单口以太网的**点云流**接入感知核（替代原 PS 侧 DMA 通路）
//
// 平台部分（时钟/复位/UART/彩条/HUD/DDR3 帧缓存/DVP 相机/单口以太网/M3TL 遥测）
// 与 fpga_acx750/rtl/acx750_top.sv 完全一致，未做改动。
//
// 分阶段调试：一条 bitstream 走完全部阶段，用串口发 '0'..'7' 在线切换。
//   0 彩条   1 DDR3 自检   2 以太网收图→DDR3→TFT   3 OV5640→DDR3→TFT
//   4 AR 合成   5 遥测发送   6 单口分流   7 HUD 演示
// 串口同时每 500ms 打印一行：
//   S=x PLL=x DDR=x CAM=x ETH=x FRM=xxxxxxxx DRP=xxxxxxxx
//
// 状态口径：**源码编写中，尚未综合/出 bit/上板验证**。
//============================================================================
`timescale 1ns/1ps

`include "acx750_defs.svh"

module acx750_full_top #(
  parameter logic [2:0] STARTUP_STAGE = `STAGE_COLORBAR,
  // disp_driver 的取数提前量：与厂商 ch57 例程一致（=2），不要随意改
  parameter integer     AHEAD_CLK_CNT = 2,
  // 帧缓存读出相对"取数请求"的流水延迟（拍）。上板调试时用 HUD/串口上的
  // DRP 计数把 stage1 的误码调到 0，用来标定 FIFO 读延迟。3 是估计初值。
  parameter integer     FB_RD_LAT     = 3,
  // 阶段切换后的清空窗口（clk_sys 拍数），期间 wrfifo 保持复位、时钟完成切换
  parameter integer     STAGE_HOLD    = 4095
)(
  // 系统与调试
  input  logic        clk50m,
  input  logic        btn_reset_n,
  output logic [3:0]  led,
  output logic        uart_txd,
  input  logic        uart_rxd,

  // 底盘串口（40 针扩展口 P11：GPIO0_34=A15 / GPIO0_35=A16）
  // 出处：厂商整板约束 ACX750_CB_PIN.xdc，详见 docs/pin_hunt_uart_gpio.md
  //       与 constraints/acx750_chassis.xdc
  output logic        chassis_txd,
  input  logic        chassis_rxd,

  // 以太网 RTL8211F RGMII
  output logic        eth_reset_n,
  output logic        eth_gtx_clk,
  output logic [3:0]  eth_txd,
  output logic        eth_tx_en,
  input  logic        eth_rx_clk,
  input  logic [3:0]  eth_rxd,
  input  logic        eth_rx_dv,
  output logic        eth_mdc,
  inout  wire         eth_mdio,

  // TFT 800x480 RGB565
  output logic [15:0] tft_rgb,
  output logic        tft_hs,
  output logic        tft_vs,
  output logic        tft_de,
  output logic        tft_clk,
  output logic        tft_pwm,

  // CMOS DVP 摄像头
  output logic        cam_xclk,
  output logic        cam_sclk,
  inout  wire         cam_sdat,
  input  logic        cam_pclk,
  input  logic        cam_vsync,
  input  logic        cam_href,
  input  logic [7:0]  cam_data,

  // DDR3
  inout  wire  [31:0] ddr3_dq,
  inout  wire  [3:0]  ddr3_dqs_n,
  inout  wire  [3:0]  ddr3_dqs_p,
  output logic [14:0] ddr3_addr,
  output logic [2:0]  ddr3_ba,
  output logic        ddr3_ras_n,
  output logic        ddr3_cas_n,
  output logic        ddr3_we_n,
  output logic        ddr3_reset_n,
  output logic [0:0]  ddr3_ck_p,
  output logic [0:0]  ddr3_ck_n,
  output logic [0:0]  ddr3_cke,
  output logic [0:0]  ddr3_cs_n,
  output logic [3:0]  ddr3_dm,
  output logic [0:0]  ddr3_odt
);

  //========================================================================
  // 0. 工具函数（必须在使用之前声明）
  //========================================================================
  // 自检图案：只依赖 (x,y)，与帧号无关 —— 这是读回比对成立的前提
  function automatic [15:0] pat_of(input logic [15:0] xx, input logic [15:0] yy);
    logic c;
    begin
      c = xx[4] ^ yy[4];
      if (xx < 16'd400)
        pat_of = c ? 16'hFFFF : 16'h0000;          // 16 像素黑白棋盘
      else if (xx < 16'd600)
        pat_of = {5'h00, yy[5:0], 5'h00};          // 绿色行号斜坡
      else
        pat_of = {xx[4:0], 6'h00, yy[4:0]};        // 红=列斜率 / 蓝=行斜率
    end
  endfunction

  //========================================================================
  // 1. 所有内部信号声明（集中放前面，避免隐式网表/前向引用问题）
  //========================================================================
  // 时钟与复位
  wire clk200, clk_sys, clk_pix, clk_camxclk, pll_locked;
  wire rst_sys_n, rst_pix_n, rst_eth_n, rst_cam_n;
  wire rst_eth_ok;

  // 阶段与统计
  wire        uart_rx_valid;
  wire [7:0]  uart_rx_byte;
  wire [2:0]  stage;
  wire        clear_stats;
  logic [2:0] stage_q;
  logic [11:0] stage_hold;
  wire        stage_busy;
  logic [16:0] ms_div;
  logic [31:0] uptime_ms;

  logic [31:0] frame_cnt_pix, mismatch_cnt;
  wire  [31:0] frame_cnt, drop_cnt, rx_pkt_cnt_sys, cam_pix_cnt;
  wire  [31:0] pts_pkt_cnt, rx_bad_cnt;
  logic [31:0] rx_pkt_cnt_eth;

  // 显示
  wire [2:0]  stage_pix;
  wire        disp_req, disp_sof;
  wire [15:0] disp_data;
  logic [11:0] px, py;
  wire [7:0]  hud_txt_addr, hud_txt_data;
  wire        hud_wr_en;
  wire [7:0]  hud_wr_addr, hud_wr_data;

  // DDR3 帧缓存
  wire        ddr3_init_done;
  wire [15:0] pat_rgb;
  logic       pat_wren;
  wire [15:0] wrfifo_din, rdfifo_dout;
  wire        wrfifo_wren, wrfifo_full, rdfifo_rden;
  wire        wrfifo_clk, wrclk_a;
  logic       sel_eth, sel_cam;
  wire        wrfifo_clr;

  // 以太网
  wire        clk125m;
  wire        rgmii_rx_clk, gmii_rx_clk;
  wire [7:0]  gmii_rxd;
  wire        gmii_rxdv;
  wire        eth_rx_byte_valid;
  wire [7:0]  eth_rx_byte_data;
  wire        eth_pkt_done, eth_pkt_error, eth_cfg_pkt_done;
  wire [15:0] eth_rx_w16;
  wire        eth_rx_w16_v;
  wire        eth_img_wren;
  wire [15:0] eth_img_data;
  wire        eth_frame_done;
  wire        eth_rx_activity;
  wire [7:0]  eth_cfg_byte;
  wire        eth_cfg_byte_v;
  wire        phy_rst_n;
  logic [26:0] act_cnt;
  wire [7:0]  tx_gmii_txd;
  wire        tx_gmii_txen, tx_gmii_tx_clk;

  //========================================================================
  // 1b. INTEG-750：相对平台基线新增的集成交互信号
  //     （感知核 / 视频 AR / 控制面 / 栅格遥测 / 底盘）
  //========================================================================
  wire        eth_cfg_pkt_error;

  // 雷达字节流：eth 域 → 控制域
  wire [7:0]  radar_data;
  wire        radar_valid, radar_last;
  wire [31:0] radar_fifo_ovf;

  // 配置字节流：eth 域 → 控制域
  wire [7:0]  cfg_stream_data;
  wire        cfg_stream_valid, cfg_stream_last;
  wire [31:0] cfg_stream_ovf;

  // 配置桥 → perception_regs（AXI-Lite 主机侧）
  wire [11:0] cb_awaddr, cb_araddr;
  wire [2:0]  cb_awprot, cb_arprot;
  wire        cb_awvalid, cb_awready, cb_wvalid, cb_wready;
  wire        cb_bvalid, cb_bready, cb_arvalid, cb_arready, cb_rvalid, cb_rready;
  wire [31:0] cb_wdata, cb_rdata;
  wire [3:0]  cb_wstrb;
  wire [1:0]  cb_bresp, cb_rresp;
  wire [31:0] cb_rb_word_index, cb_rb_value;
  wire        cb_rb_valid;
  wire [31:0] cb_pkt_cnt, cb_bad_cnt;

  // perception_regs → 感知引擎
  wire [2047:0] pr_cfg;
  wire [7071:0] pr_lut;
  wire          pr_cfg_pending, pr_cfg_safe;
  wire          pr_snapshot_start;
  wire [1023:0] pr_metadata;
  wire [4:0]    pr_object_index;
  wire          pr_snapshot_busy;
  wire [383:0]  pr_object_data;

  // 视频 / AR
  wire [15:0]   disp_final;      // 显示最终数据：AR 阶段取 ar_disp_out，否则取平台像素源
  wire [15:0]   ar_disp_out;
  wire          ar_video_ready;
  wire [11:0]   grid_rd_addr;
  wire [7:0]    grid_rd_data;

  // 栅格读出
  wire          grid_busy, grid_done;
  wire [7:0]    grid_byte;
  wire          grid_byte_valid;
  wire [15:0]   grid_byte_index;
  wire [15:0]   grid_rd_test_addr;

  // 底盘 Odom
  wire [7:0]    odom_data;
  wire          odom_valid, odom_last;
  wire [31:0]   ch_rx_byte_cnt, ch_frame_ok, ch_frame_bad, ch_uart_err;

  // M3TL 完整遥测发送（复用平台上已有的 m3tl_* 连线，只多一个栅格计数）
  wire [31:0]   m3tl_grid_cnt;
  wire [63:0]   now_us;

  // type=3 目标表（旁路监听快照走查，不驱动快照接口）
  wire [7:0]    tgt_count, tgt_overflow;
  wire [4127:0] tgt_payload;        // 4B 头 + 32×16B
  wire          tgt_valid, tgt_ack;
  wire [31:0]   tgt_rx_cnt;

  // 以太网发送
  wire        arp_start, arp_busy;
  wire [15:0] arp_len, arp_idx;
  wire [7:0]  arp_val;
  wire [47:0] peer_mac;
  wire [31:0] peer_ip;
  wire [31:0] arp_req_cnt, arp_rsp_cnt;
  wire        m3tl_start, m3tl_busy, m3tl_req;
  wire        arb_p1_busy;      // 仲裁器回读的"路 1 忙"，与 m3tl_busy 分开，
                                // 否则两个 output 会驱动同一根线（双驱动冲突）
  wire [15:0] m3tl_len;
  wire [7:0]  m3tl_payload;
  wire [31:0] m3tl_pkt_cnt;

  // 摄像头
  wire        cam_init_done;
  wire        cam_pclk_bufg;
  wire        cam_wren;
  wire [15:0] cam_data_pix;
  logic [31:0] cam_wr_cnt;

  // 自检比对
  logic [11:0] lat_x [0:7];
  logic [11:0] lat_y [0:7];
  logic [15:0] cmp_exp;
  logic        cmp_en;
  logic [2:0]  stage_pix_q;
  integer      k;

  //========================================================================
  // 2. 时钟：50 MHz → 200 / 100 / 33 / 24 MHz
  //========================================================================
  clk_sys_wiz u_clk_wiz (
    .clk_in1  (clk50m),
    .resetn   (btn_reset_n),
    .clk_out1 (clk200),
    .clk_out2 (clk_sys),
    .clk_out3 (clk_pix),
    .clk_out4 (clk_camxclk),
    .locked   (pll_locked)
  );

  assign cam_xclk = clk_camxclk;

  //========================================================================
  // 3. 复位
  //========================================================================
  acx750_reset #(.DEBOUNCE_CLK(1_000_000)) u_rst_sys (
    .clk(clk_sys), .locked(pll_locked),
    .btn_reset_n(btn_reset_n), .rst_n(rst_sys_n));

  acx750_rst_sync u_rst_pix (.clk(clk_pix), .arst_n(rst_sys_n), .rst_n(rst_pix_n));

  // 以太网逻辑要等 DDR3 校准完再放开（与厂商 ch57 一致）
  assign rst_eth_ok = rst_sys_n && ddr3_init_done;

  //========================================================================
  // 4. 阶段控制 + 串口
  //========================================================================
  acx750_uart_rx #(.CLK_HZ(100_000_000), .BAUD(115_200)) u_uart_rx (
    .clk(clk_sys), .rst_n(rst_sys_n), .rxd(uart_rxd),
    .rx_data(uart_rx_byte), .rx_data_valid(uart_rx_valid));

  acx750_cmd #(.STARTUP_STAGE(STARTUP_STAGE)) u_cmd (
    .clk(clk_sys), .rst_n(rst_sys_n),
    .rx_valid(uart_rx_valid), .rx_data(uart_rx_byte),
    .stage(stage), .clear_stats(clear_stats));

  // 阶段切换后的清空窗口：期间 wrfifo 复位、写时钟完成切换
  always_ff @(posedge clk_sys or negedge rst_sys_n) begin
    if (!rst_sys_n) begin
      stage_q    <= STARTUP_STAGE;
      stage_hold <= STAGE_HOLD[11:0];
    end else begin
      stage_q <= stage;
      if (stage != stage_q)
        stage_hold <= STAGE_HOLD[11:0];
      else if (stage_hold != 12'h000)
        stage_hold <= stage_hold - 12'd1;
    end
  end
  assign stage_busy = (stage_hold != 12'h000);

  // 1 ms 时基（M3TL 时间戳、点亮时长等）
  always_ff @(posedge clk_sys or negedge rst_sys_n) begin
    if (!rst_sys_n) begin
      ms_div    <= '0;
      uptime_ms <= '0;
    end else if (ms_div == 17'd99_999) begin
      ms_div    <= '0;
      uptime_ms <= uptime_ms + 32'd1;
    end else begin
      ms_div <= ms_div + 17'd1;
    end
  end

  // 统计清零在各自时钟域内完成（见像素域/相机域/以太网域各自的 always_ff），
  // 这里不集中复位，避免跨域误清。

  //========================================================================
  // 5. LED 与串口上报
  //========================================================================
  wire breath, beat_pulse;
  acx750_led_beat #(.SYS_HZ(100_000_000), .BEAT_HZ(4)) u_beat (
    .clk(clk_sys), .rst_n(rst_sys_n),
    .beat_pulse(beat_pulse), .breath(breath));

  assign led[0] = breath;             // 呼吸：板卡在跑
  assign led[1] = pll_locked;         // MMCM 锁定
  assign led[2] = ddr3_init_done;     // DDR3 校准完成
  assign led[3] = eth_rx_activity;    // 网口有帧

  acx750_uart_report #(.CLK_HZ(100_000_000), .BAUD(115_200), .PERIOD_MS(500)) u_report (
    .clk(clk_sys), .rst_n(rst_sys_n),
    .stage(stage),
    .pll_locked(pll_locked),
    .ddr3_done(ddr3_init_done),
    .cam_done(cam_init_done),
    .eth_up(eth_rx_activity),
    .frame_cnt(frame_cnt),
    .drop_cnt(drop_cnt),
    .txd(uart_txd));

  //========================================================================
  // 6. 显示：时序发生器 + 像素源 + HUD
  //========================================================================
  (* ASYNC_REG = "TRUE" *) logic [2:0] stage_pix_s1, stage_pix_s2;
  always_ff @(posedge clk_pix or negedge rst_pix_n) begin
    if (!rst_pix_n) begin
      stage_pix_s1 <= STARTUP_STAGE;
      stage_pix_s2 <= STARTUP_STAGE;
    end else begin
      stage_pix_s1 <= stage;
      stage_pix_s2 <= stage_pix_s1;
    end
  end
  assign stage_pix = stage_pix_s2;

  // 像素域坐标：由 disp_driver 的取数脉冲按光栅顺序推出
  always_ff @(posedge clk_pix or negedge rst_pix_n) begin
    if (!rst_pix_n) begin
      px <= '0;
      py <= '0;
    end else if (disp_sof) begin
      px <= '0;
      py <= '0;
    end else if (disp_req) begin
      px <= (px == (`DISP_WIDTH-1)) ? 12'd0 : (px + 12'd1);
      if (px == (`DISP_WIDTH-1))
        py <= (py == (`DISP_HEIGHT-1)) ? 12'd0 : (py + 12'd1);
    end
  end

  disp_driver #(.AHEAD_CLK_CNT(AHEAD_CLK_CNT)) u_disp (
    .ClkDisp    (clk_pix),
    .Rst_n      (rst_pix_n),
    .Data       (disp_final),
    .DataReq    (disp_req),
    .H_Addr     (),
    .V_Addr     (),
    .Disp_Sof   (disp_sof),
    .Disp_HS    (tft_hs),
    .Disp_VS    (tft_vs),
    .Disp_Red   (tft_rgb[15:11]),
    .Disp_Green (tft_rgb[10:5]),
    .Disp_Blue  (tft_rgb[4:0]),
    .Disp_DE    (tft_de),
    .Disp_PCLK  (tft_clk));

  assign tft_pwm = 1'b1;              // 背光常亮

  acx750_hud_text #(.CLK_HZ(100_000_000), .REFRESH_MS(250)) u_hud_text (
    .clk(clk_sys), .rst_n(rst_sys_n),
    .stage(stage),
    .pll_locked(pll_locked), .ddr3_done(ddr3_init_done),
    .cam_done(cam_init_done), .eth_up(eth_rx_activity),
    .frame_cnt(frame_cnt), .rx_pkt_cnt(rx_pkt_cnt_sys), .drop_cnt(drop_cnt),
    .cam_frame_cnt(cam_pix_cnt), .pts_pkt_cnt(pts_pkt_cnt),
    .wr_en(hud_wr_en), .wr_addr(hud_wr_addr), .wr_data(hud_wr_data));

  acx750_hud_ram u_hud_ram (
    .wr_clk(clk_sys), .wr_en(hud_wr_en),
    .wr_addr(hud_wr_addr), .wr_data(hud_wr_data),
    .rd_clk(clk_pix), .rd_addr(hud_txt_addr), .rd_data(hud_txt_data));

  acx750_video_src u_video (
    .pix_clk(clk_pix), .pix_rst_n(rst_pix_n),
    .req(disp_req), .sof(disp_sof), .stage(stage_pix),
    .fb_dout(rdfifo_dout),
    .cam_dout(16'h0000),             // 摄像头同样经帧缓存，不经直通
    .hud_txt_addr(hud_txt_addr), .hud_txt_data(hud_txt_data),
    .data(disp_data));

  //========================================================================
  // 7. DDR3 帧缓存
  //========================================================================
  // 写时钟三选一（无毛刺 BUFGMUX 级联）。sel 只在 stage_hold 的后半段翻转，
  // 保证切换发生在 wrfifo 处于异步复位期间，不会产生半个写脉冲。
  wire sel_win = (stage_hold < {1'b0, STAGE_HOLD[11:1]});   // 后半段

  always_ff @(posedge clk_sys or negedge rst_sys_n) begin
    if (!rst_sys_n) begin
      sel_eth <= 1'b0;
      sel_cam <= 1'b0;
    end else begin
      sel_eth <= (stage == `STAGE_ETH_IMAGE) && sel_win;
      sel_cam <= (stage == `STAGE_CAMERA)    && sel_win;
    end
  end

  BUFGMUX u_wrclk_a (.O(wrclk_a),    .I0(clk_pix), .I1(clk125m),       .S(sel_eth));
  BUFGMUX u_wrclk_b (.O(wrfifo_clk), .I0(wrclk_a), .I1(cam_pclk_bufg), .S(sel_cam));

  assign wrfifo_clr = (!rst_sys_n) || stage_busy;

  ddr3_ctrl_2port #(
    .FIFO_DW            (16),
    .WR_BYTE_ADDR_BEGIN (0),
    .WR_BYTE_ADDR_END   (`DISP_WIDTH*`DISP_HEIGHT*2-1),
    .RD_BYTE_ADDR_BEGIN (0),
    .RD_BYTE_ADDR_END   (`DISP_WIDTH*`DISP_HEIGHT*2-1),
    .FIFO_ADDR_DEPTH    (64)
  ) u_fb (
    .ddr3_clk200m  (clk200),
    .ddr3_rst_n    (pll_locked),
    .ddr3_init_done(ddr3_init_done),
    .wrfifo_clr    (wrfifo_clr),
    .wrfifo_clk    (wrfifo_clk),
    .wrfifo_wren   (wrfifo_wren),
    .wrfifo_din    (wrfifo_din),
    .wrfifo_full   (wrfifo_full),
    .wrfifo_wr_cnt (),
    .rdfifo_clr    (disp_sof),
    .rdfifo_clk    (clk_pix),
    .rdfifo_rden   (rdfifo_rden),
    .rdfifo_dout   (rdfifo_dout),
    .rdfifo_empty  (),
    .rdfifo_rd_cnt (),
    .ddr3_dq       (ddr3_dq),
    .ddr3_dqs_n    (ddr3_dqs_n),
    .ddr3_dqs_p    (ddr3_dqs_p),
    .ddr3_addr     (ddr3_addr),
    .ddr3_ba       (ddr3_ba),
    .ddr3_ras_n    (ddr3_ras_n),
    .ddr3_cas_n    (ddr3_cas_n),
    .ddr3_we_n     (ddr3_we_n),
    .ddr3_reset_n  (ddr3_reset_n),
    .ddr3_ck_p     (ddr3_ck_p),
    .ddr3_ck_n     (ddr3_ck_n),
    .ddr3_cke      (ddr3_cke),
    .ddr3_cs_n     (ddr3_cs_n),
    .ddr3_dm       (ddr3_dm),
    .ddr3_odt      (ddr3_odt));

  // 读始终跟着显示取数脉冲走（与厂商 ch57 一致）
  assign rdfifo_rden = disp_req;

  // 自检图案：由 disp_req 驱动，与读侧 1:1
  acx750_self_pattern u_pat (.x(px), .y(py), .rgb(pat_rgb));

  always_ff @(posedge clk_pix or negedge rst_pix_n) begin
    if (!rst_pix_n) pat_wren <= 1'b0;
    else            pat_wren <= disp_req && (stage_pix == `STAGE_DDR3_SELF);
  end

  // 写侧三选一
  assign wrfifo_wren = sel_eth ? eth_img_wren : (sel_cam ? cam_wren : pat_wren);
  assign wrfifo_din  = sel_eth ? eth_img_data : (sel_cam ? cam_data_pix : pat_rgb);

  //------------------------------------------------------------------
  // 自检读回比对（只有 stage 1 有意义）
  // 期望值取 FB_RD_LAT 拍之前的坐标，用来标定 FIFO 读延迟
  //------------------------------------------------------------------
  always_ff @(posedge clk_pix or negedge rst_pix_n) begin
    if (!rst_pix_n) begin
      for (k = 0; k < 8; k = k + 1) begin
        lat_x[k] <= 12'd0;
        lat_y[k] <= 12'd0;
      end
      cmp_exp      <= 16'd0;
      cmp_en       <= 1'b0;
      mismatch_cnt <= 32'd0;
      stage_pix_q  <= STARTUP_STAGE;
      frame_cnt_pix<= 32'd0;
    end else begin
      stage_pix_q <= stage_pix;
      if (stage_pix != stage_pix_q)
        mismatch_cnt <= 32'd0;                    // 换阶段清计数

      if (disp_sof)
        frame_cnt_pix <= frame_cnt_pix + 32'd1;

      // 坐标延迟线
      lat_x[0] <= px;
      lat_y[0] <= py;
      for (k = 1; k < 8; k = k + 1) begin
        lat_x[k] <= lat_x[k-1];
        lat_y[k] <= lat_y[k-1];
      end

      cmp_en <= (stage_pix == `STAGE_DDR3_SELF) && ddr3_init_done && !stage_busy;
      if ((stage_pix == `STAGE_DDR3_SELF) && ddr3_init_done && !stage_busy)
        cmp_exp <= pat_of({4'b0, lat_x[FB_RD_LAT[2:0]]}, {4'b0, lat_y[FB_RD_LAT[2:0]]});

      // 注意用 != 而不是 !==：综合里 !== 会被降级成 !=（Synth 8-589），
      // 硬件上没有 X，两者等价，直接写 != 更清楚。
      if (cmp_en && (rdfifo_dout != cmp_exp))
        mismatch_cnt <= mismatch_cnt + 32'd1;
    end
  end

  //========================================================================
  // 8. 以太网（单口）
  //========================================================================
  eth_phase_mmcm u_eth_mmcm (
    .clk_in1 (eth_rx_clk),
    .clk_out1(rgmii_rx_clk),
    .locked  ());

  rgmii_to_gmii u_rgmii2gmii (
    .reset_n     (rst_sys_n),
    .gmii_rx_clk (gmii_rx_clk),
    .gmii_rxd    (gmii_rxd),
    .gmii_rxdv   (gmii_rxdv),
    .gmii_rxerr  (),
    .rgmii_rx_clk(rgmii_rx_clk),
    .rgmii_rxd   (eth_rxd),
    .rgmii_rxdv  (eth_rx_dv));

  //------------------------------------------------------------------
  // 网口时钟：MMCM 原始输出 → 唯一一个 BUFG
  //
  // 我们**不再使用厂商的 eth_udp_rx_gmii**，因为它内部自带
  // `BUFG BUFG_pclk(.I(gmii_rx_clk),...)`，一个 MMCM 输出脚上挂两份会
  // 在实现阶段报错（7 系列 MMCM 输出只能经专用布线驱动一个 BUFG）。
  // 改用自写的 acx750_udp_rx（不含 BUFG），于是**一个 BUFG 可以带任意多个
  // UDP 服务端口**，想加端口只是多例化一份、改一个 local_port 参数。
  // 厂商版保留在 rtl/vendor_ref/eth_rx/ 作对拍基准。
  // 详见 docs/known_gaps.md G8 与 docs/udp_rx_750.md。
  //------------------------------------------------------------------
  BUFG u_bufg_eth (.I(gmii_rx_clk), .O(clk125m));

  // 流 0：雷达点云（MID-360 -> PL:56301）
  acx750_udp_rx u_udp_pts (
    .clk            (clk125m),
    .reset          (~rst_eth_ok),
    .local_mac      (`PL_MAC),
    .local_ip       (`PL_IP),
    .local_port     (`RADAR_PORT),
    .exter_mac      (),
    .exter_ip       (),
    .exter_port     (),
    .rx_data_length (),
    .data_overflow_i(1'b0),
    .payload_valid_o(eth_rx_byte_valid),
    .payload_dat_o  (eth_rx_byte_data),
    .one_pkt_done   (eth_pkt_done),
    .pkt_error      (eth_pkt_error),
    .gmii_rxd       (gmii_rxd),
    .gmii_rxdv      (gmii_rxdv));

  // 流 1：上位机下行配置（树莓派 -> PL:56300）
  acx750_udp_rx u_udp_cfg (
    .clk            (clk125m),
    .reset          (~rst_eth_ok),
    .local_mac      (`PL_MAC),
    .local_ip       (`PL_IP),
    .local_port     (`CONFIG_PORT),
    .exter_mac      (),
    .exter_ip       (),
    .exter_port     (),
    .rx_data_length (),
    .data_overflow_i(1'b0),
    .payload_valid_o(eth_cfg_byte_v),
    .payload_dat_o  (eth_cfg_byte),
    .one_pkt_done   (eth_cfg_pkt_done),
    .pkt_error      (eth_cfg_pkt_error),
    .gmii_rxd       (gmii_rxd),
    .gmii_rxdv      (gmii_rxdv));

  // 网口逻辑复位（clk125m 已存在，可以安全同步）
  acx750_rst_sync u_rst_eth (.clk(clk125m), .arst_n(rst_eth_ok), .rst_n(rst_eth_n));

  // 字节流 → 16bit 流（厂商 ch57 通路，stage2 的"收图"）
  eth_rx_ctrl #(.O_DATA_WIDTH(16)) u_rx_ctrl (
    .clk          (clk125m),
    .reset        (~rst_eth_n),
    .fifo_full    (),
    .fifo_wr      (eth_rx_byte_valid),
    .fifo_din     (eth_rx_byte_data),
    .one_pkt_done (eth_pkt_done),
    .pkt_error    (eth_pkt_error),
    .rx_data      (eth_rx_w16),
    .rx_data_valid(eth_rx_w16_v));

  frame_check #(
    .IMAGE_WIDTH (`DISP_WIDTH),
    .IMAGE_HEIGHT(`DISP_HEIGHT),
    .DATA_WIDTH  (16)
  ) u_frame_check (
    .clk            (clk125m),
    .reset          (~rst_eth_n),
    .data_i         ({eth_rx_w16[7:0], eth_rx_w16[15:8]}),   // 厂商字节序
    .data_i_valid   (eth_rx_w16_v),
    .data_o_valid   (eth_img_wren),
    .data_o         (eth_img_data),
    .frame_dis_pulse(eth_frame_done));

  // 接收活动指示（无点云时也要能看出链路在不在收帧）
  always_ff @(posedge clk125m or negedge rst_eth_n) begin
    if (!rst_eth_n) begin
      act_cnt <= '0;
    end else if (eth_pkt_done) begin
      act_cnt <= 27'h7FFFFFF;
    end else if (act_cnt != '0) begin
      act_cnt <= act_cnt - 27'd1;
    end
  end
  assign eth_rx_activity = (act_cnt != '0);

  always_ff @(posedge clk125m or negedge rst_eth_n) begin
    if (!rst_eth_n) rx_pkt_cnt_eth <= 32'd0;
    else if (eth_pkt_done) rx_pkt_cnt_eth <= rx_pkt_cnt_eth + 32'd1;
  end

  // PHY 复位与 MDIO
  phy_reg_config #(
    .speed     (2'b01),                 // 百兆起步，与厂商一致
    .SYS_CLOCK (100_000_000),
    .MDC_CLOCK (1_000_000),
    .MAX_CNT   (2)
  ) u_phy_cfg (
    .clk          (clk_sys),
    .rst_n        (rst_sys_n),
    .phy_rst_n    (phy_rst_n),
    .rddata       (),
    .phy_init_done(),
    .mdc          (eth_mdc),
    .mdio         (eth_mdio));

  assign eth_reset_n = phy_rst_n;

  // 发送：ARP 应答 + M3TL 遥测，共用唯一 PHY
  acx750_arp_reply u_arp (
    .clk125m     (clk125m),
    .rst_n       (rst_eth_n),
    .gmii_rxd    (gmii_rxd),
    .gmii_rxdv   (gmii_rxdv),
    .reply_start (arp_start),
    .reply_len   (arp_len),
    .reply_idx   (arp_idx),
    .reply_val   (arp_val),
    .arp_req_cnt (arp_req_cnt),
    .arp_rsp_cnt (arp_rsp_cnt),
    .peer_mac    (peer_mac),
    .peer_ip     (peer_ip));

  // 对端 MAC 未知时用广播，保证遥测仍能被树莓派收到
  wire [47:0] telem_dst_mac = (peer_mac == 48'h0) ? 48'hFF_FF_FF_FF_FF_FF : peer_mac;

  // M3TL 遥测：用"完整版"（在平台上原 m3tl_tx 的 type=1/6 之上，
  // 增加 type=5 栅格遥测与 type=7 配置回读应答）。
  // 注意：cfg_rb_* 来自控制域（clk_sys），本模块在 eth 域（clk125m）——
  // 下面用了两级同步器搬 2 个 32bit 值 + 一个 valid 脉冲，属"慢速统计型"
  // 跨域，允许极低概率的瞬时不自洽（只影响回读显示，不影响控制）。
  (* ASYNC_REG = "TRUE" *) logic        cfg_rb_v_s1, cfg_rb_v_s2;
  (* ASYNC_REG = "TRUE" *) logic [31:0] cfg_rb_idx_s1, cfg_rb_idx_s2;
  (* ASYNC_REG = "TRUE" *) logic [31:0] cfg_rb_val_s1, cfg_rb_val_s2;

  always_ff @(posedge clk125m or negedge rst_eth_n) begin
    if (!rst_eth_n) begin
      cfg_rb_v_s1   <= 1'b0;
      cfg_rb_v_s2   <= 1'b0;
      cfg_rb_idx_s1 <= 32'd0;
      cfg_rb_idx_s2 <= 32'd0;
      cfg_rb_val_s1 <= 32'd0;
      cfg_rb_val_s2 <= 32'd0;
    end else begin
      cfg_rb_v_s1   <= cb_rb_valid;
      cfg_rb_v_s2   <= cfg_rb_v_s1;
      cfg_rb_idx_s1 <= cb_rb_word_index;
      cfg_rb_idx_s2 <= cfg_rb_idx_s1;
      cfg_rb_val_s1 <= cb_rb_value;
      cfg_rb_val_s2 <= cfg_rb_val_s1;
    end
  end

  acx750_m3tl_full_tx #(
    .CLK_HZ        (125_000_000),
    .HB_PERIOD_MS  (500),
    .CAM_PERIOD_MS (1000),
    .GRID_PERIOD_MS(1000)
  ) u_m3tl (
    .clk125m      (clk125m),
    .rst_n        (rst_eth_n),
    .stat_flags   ({4'b0, cam_init_done, eth_rx_activity, ddr3_init_done, pll_locked}),
    .stage        (stage),
    .uptime_ms    (uptime_ms),
    .drop_count   (drop_cnt),
    .cam_frames   (cam_pix_cnt),
    .cam_last_ms  (32'd0),
    .cam_width    (16'd640),
    .cam_height   (16'd480),
    .grid_byte       (grid_byte),
    .grid_byte_valid (grid_byte_valid),
    .grid_snapshot_start(grid_snapshot_start),
    .grid_snapshot_done (grid_done),
    .grid_rows       (16'd55),
    .grid_cols       (16'd60),
    .grid_cell_mm    (16'd100),
    .cfg_rb_word_index(cfg_rb_idx_s2),
    .cfg_rb_value     (cfg_rb_val_s2),
    .cfg_rb_valid     (cfg_rb_v_s2 & ~cfg_rb_v_s1 & rst_eth_n),
    .dst_mac      (telem_dst_mac),
    .dst_ip       (`HOST_IP),
    .tx_start     (m3tl_start),
    .tx_len       (m3tl_len),
    .tx_req       (m3tl_req),
    .tx_payload   (m3tl_payload),
    .tx_busy      (m3tl_busy),
    .tx_pkt_cnt   (m3tl_pkt_cnt),
    .grid_tx_cnt  (m3tl_grid_cnt),
    .tgt_count    (tgt_count),
    .tgt_overflow (tgt_overflow),
    .tgt_payload  (tgt_payload),
    .tgt_valid    (tgt_valid),
    .tgt_ack      (tgt_ack));

  acx750_eth_tx_arb u_tx_arb (
    .clk125m    (clk125m),
    .rst_n      (rst_eth_n),
    .p0_start   (arp_start),
    .p0_len     (arp_len),
    .p0_idx     (arp_idx),
    .p0_val     (arp_val),
    .p0_busy    (arp_busy),
    .p1_start   (m3tl_start),
    .p1_len     (m3tl_len),
    .p1_dst_mac (telem_dst_mac),
    .p1_src_mac (`PL_MAC),
    .p1_dst_ip  (`HOST_IP),
    .p1_src_ip  (`PL_IP),
    .p1_dst_port(`TELEM_PORT),
    .p1_src_port(`RADAR_PORT),
    .p1_req     (m3tl_req),
    .p1_payload (m3tl_payload),
    .p1_busy    (arb_p1_busy),
    .gmii_tx_clk(tx_gmii_tx_clk),
    .gmii_txd   (tx_gmii_txd),
    .gmii_txen  (tx_gmii_txen));

  // GMII → RGMII（ODDR，输出 TX 时钟；厂商 gmii_to_rgmii 负责 8bit→4bit DDR）
  gmii_to_rgmii u_gmii2rgmii (
    .reset_n     (rst_eth_n),
    .gmii_tx_clk (tx_gmii_tx_clk),
    .gmii_txd    (tx_gmii_txd),
    .gmii_txen   (tx_gmii_txen),
    .gmii_txer   (1'b0),
    .rgmii_tx_clk(eth_gtx_clk),
    .rgmii_txd   (eth_txd),
    .rgmii_txen  (eth_tx_en));

  //========================================================================
  // 9. 摄像头（OV5640 / ACM5640-V5，DVP）
  //========================================================================
  BUFG u_cam_bufg (.I(cam_pclk), .O(cam_pclk_bufg));

  acx750_rst_sync u_rst_cam (.clk(cam_pclk_bufg), .arst_n(rst_sys_n), .rst_n(rst_cam_n));

  camera_init #(
    .CAMERA_TYPE    ("ov5640"),
    .IMAGE_TYPE     (0),                // RGB（不是 JPEG）
    .IMAGE_WIDTH    (640),
    .IMAGE_HEIGHT   (480),
    .IMAGE_FLIP_EN  (0),
    .IMAGE_MIRROR_EN(0)
  ) u_cam_init (
    .Clk         (clk_sys),
    .Rst_n       (rst_sys_n),
    .Init_Done   (cam_init_done),
    .camera_rst_n(),
    .camera_pwdn (),
    .i2c_sclk    (cam_sclk),
    .i2c_sdat    (cam_sdat));

  DVP_Capture u_dvp (
    .Rst_p     (~rst_cam_n),
    .PCLK      (cam_pclk_bufg),
    .Vsync     (cam_vsync),
    .Href      (cam_href),
    .Data      (cam_data),
    .ImageState(),
    .DataValid (cam_wren),
    .DataPixel (cam_data_pix),
    .DataHs    (),
    .DataVs    (),
    .Xaddr     (),
    .Yaddr     ());

  always_ff @(posedge cam_pclk_bufg or negedge rst_cam_n) begin
    if (!rst_cam_n) cam_wr_cnt <= 32'd0;
    else if (cam_wren) cam_wr_cnt <= cam_wr_cnt + 32'd1;
  end

  //========================================================================
  // 10. 跨域统计同步（只用于显示与低带宽遥测，允许瞬时不自洽）
  //========================================================================
  acx750_sync_word #(.WIDTH(32)) u_sync_frm (
    .clk(clk_sys), .rst_n(rst_sys_n), .d(frame_cnt_pix), .q(frame_cnt));

  acx750_sync_word #(.WIDTH(32)) u_sync_drp (
    .clk(clk_sys), .rst_n(rst_sys_n), .d(mismatch_cnt),  .q(drop_cnt));

  acx750_sync_word #(.WIDTH(32)) u_sync_cam (
    .clk(clk_sys), .rst_n(rst_sys_n), .d(cam_wr_cnt),    .q(cam_pix_cnt));

  acx750_sync_word #(.WIDTH(32)) u_sync_arp (
    .clk(clk_sys), .rst_n(rst_sys_n), .d(arp_req_cnt),   .q(pts_pkt_cnt));

  acx750_sync_word #(.WIDTH(32)) u_sync_bad (
    .clk(clk_sys), .rst_n(rst_sys_n), .d(arp_rsp_cnt),   .q(rx_bad_cnt));

  acx750_sync_word #(.WIDTH(32)) u_sync_rxp (
    .clk(clk_sys), .rst_n(rst_sys_n), .d(rx_pkt_cnt_eth), .q(rx_pkt_cnt_sys));

  //========================================================================
  // 11. INTEG-750：把 XC7Z020 侧的感知 / AR 接进来
  //
  // 数据流总览：
  //   雷达点云  eth125 ──异步FIFO──> clk_sys ──> perception_engine(engine)
  //   下行配置  eth125 ──异步FIFO──> clk_sys ──> cfg_bridge ──AXI-Lite──>
  //                                              perception_regs ──cfg/lut──> engine
  //   视频     DDR3帧缓存 ──拉取式光栅──> 光栅AXIS ──> engine(ar_video 叠加)
  //                                              ──> disp_driver.Data
  //   遥测     engine 栅格/配置回读 ──> M3TL full tx ──> 单口 PHY
  //========================================================================

  // 微秒时基（感知核 now_us 用）
  assign now_us = {32'd0, uptime_ms} * 64'd1000;

  //------------------------------------------------------------------
  // 11.1 雷达点云：eth 域字节流 →（异步 FIFO）→ 控制域
  //------------------------------------------------------------------
  acx750_radar_stream u_radar_stream (
    .eth_clk          (clk125m),
    .eth_rst_n        (rst_eth_n),
    .eth_valid        (eth_rx_byte_valid),
    .eth_data         (eth_rx_byte_data),
    .eth_pkt_done     (eth_pkt_done),
    .clk              (clk_sys),
    .rst_n            (rst_sys_n),
    .radar_data       (radar_data),
    .radar_valid      (radar_valid),
    .radar_last       (radar_last),
    .fifo_overflow_cnt(radar_fifo_ovf));

  //------------------------------------------------------------------
  // 11.2 下行配置：eth 域字节流 →（异步 FIFO）→ 控制域 → 配置桥 → 寄存器组
  //      （复用 acx750_radar_stream 的通用"字节流 + last"异步搬移）
  //------------------------------------------------------------------
  acx750_radar_stream u_cfg_stream (
    .eth_clk          (clk125m),
    .eth_rst_n        (rst_eth_n),
    .eth_valid        (eth_cfg_byte_v),
    .eth_data         (eth_cfg_byte),
    .eth_pkt_done     (eth_cfg_pkt_done),
    .clk              (clk_sys),
    .rst_n            (rst_sys_n),
    .radar_data       (cfg_stream_data),
    .radar_valid      (cfg_stream_valid),
    .radar_last       (cfg_stream_last),
    .fifo_overflow_cnt(cfg_stream_ovf));

  acx750_cfg_bridge u_cfg_bridge (
    .clk(clk_sys), .rst_n(rst_sys_n),
    .cfg_data (cfg_stream_data),
    .cfg_valid(cfg_stream_valid),
    .cfg_last (cfg_stream_last),
    .m_axi_awaddr (cb_awaddr),  .m_axi_awprot (cb_awprot),
    .m_axi_awvalid(cb_awvalid), .m_axi_awready(cb_awready),
    .m_axi_wdata  (cb_wdata),   .m_axi_wstrb  (cb_wstrb),
    .m_axi_wvalid (cb_wvalid),  .m_axi_wready (cb_wready),
    .m_axi_bresp  (cb_bresp),   .m_axi_bvalid (cb_bvalid), .m_axi_bready(cb_bready),
    .m_axi_araddr (cb_araddr),  .m_axi_arprot (cb_arprot),
    .m_axi_arvalid(cb_arvalid), .m_axi_arready(cb_arready),
    .m_axi_rdata  (cb_rdata),   .m_axi_rresp  (cb_rresp),
    .m_axi_rvalid (cb_rvalid),  .m_axi_rready (cb_rready),
    .rb_word_index(cb_rb_word_index), .rb_value(cb_rb_value), .rb_valid(cb_rb_valid),
    .cfg_pkt_cnt  (cb_pkt_cnt), .cfg_bad_cnt  (cb_bad_cnt));

  perception_regs u_percep_regs (
    .s_axi_aclk   (clk_sys),
    .s_axi_aresetn(rst_sys_n),
    .s_axi_awaddr (cb_awaddr),  .s_axi_awprot (cb_awprot),
    .s_axi_awvalid(cb_awvalid), .s_axi_awready(cb_awready),
    .s_axi_wdata  (cb_wdata),   .s_axi_wstrb  (cb_wstrb),
    .s_axi_wvalid (cb_wvalid),  .s_axi_wready (cb_wready),
    .s_axi_bresp  (cb_bresp),   .s_axi_bvalid (cb_bvalid), .s_axi_bready(cb_bready),
    .s_axi_araddr (cb_araddr),  .s_axi_arprot (cb_arprot),
    .s_axi_arvalid(cb_arvalid), .s_axi_arready(cb_arready),
    .s_axi_rdata  (cb_rdata),   .s_axi_rresp  (cb_rresp),
    .s_axi_rvalid (cb_rvalid),  .s_axi_rready (cb_rready),
    .config_words (pr_cfg),     .lut_words    (pr_lut),
    .config_pending(pr_cfg_pending), .config_safe(pr_cfg_safe),
    .snapshot_start(pr_snapshot_start), .metadata(pr_metadata),
    .object_data  (pr_object_data), .object_index(pr_object_index),
    .snapshot_busy(pr_snapshot_busy));

  //------------------------------------------------------------------
  // 11.3 底盘 Odom 串口（40 针扩展口 P11：GPIO0_34=A15 TX / GPIO0_35=A16 RX）
  //
  // 管脚已确认（出处见 docs/pin_hunt_uart_gpio.md 与 constraints/acx750_chassis.xdc）。
  // 上板前仍需：用万用表核对 P11-39/40 空闲电平约 3.3 V，并确认底盘与板卡**共地**；
  //             底盘独立供电，**不要**接 P11 的 3.3 V 供电脚。
  //
  // TODO(750)：向底盘发送的那条链路（原 7020 的 odom_uart_tx）本轮未实现，
  //            chassis_txd 先固定为 UART 空闲高。若后续需要给底盘下命令，
  //            把 uart_tx_8n1 搬进来接上即可。
  //------------------------------------------------------------------
  assign chassis_txd = 1'b1;
  acx750_chassis_rx #(.CLK_HZ(100_000_000), .BAUD(460_800)) u_chassis (
    .clk          (clk_sys),
    .rst_n        (rst_sys_n),
    .chassis_rxd  (chassis_rxd),
    .odom_data    (odom_data),
    .odom_valid   (odom_valid),
    .odom_last    (odom_last),
    .rx_byte_cnt  (ch_rx_byte_cnt),
    .frame_ok_cnt (ch_frame_ok),
    .frame_bad_cnt(ch_frame_bad),
    .uart_err_cnt (ch_uart_err));

  //------------------------------------------------------------------
  // 11.4 显示：AR 阶段用感知核叠加后的像素，其它阶段用平台像素源
  //      （实测 ar_wrap 的 s→m 延迟 = 1 拍，配合 valid=disp_req
  //        正好落在 disp_driver 需要的 DataReq+1 拍，**无需额外补偿**）
  //------------------------------------------------------------------
  acx750_ar_wrap u_ar (
    .clk(clk_sys), .rst_n(rst_sys_n),
    .now_us(now_us),
    .radar_data (radar_data),  .radar_valid(radar_valid), .radar_last(radar_last),
    .odom_data  (odom_data),   .odom_valid (odom_valid),  .odom_last (odom_last),
    .src_fifo_overflow   (radar_fifo_ovf),
    .src_eth_rejected    (cb_bad_cnt),
    .src_odom_bad        (ch_frame_bad),
    .src_odom_busy       (32'd0),
    .src_radar_slot_drops(32'd0),
    .src_chassis_slot_drops(32'd0),
    .cfg(pr_cfg), .lut(pr_lut),
    .cfg_pending(pr_cfg_pending), .cfg_safe(pr_cfg_safe),
    .snapshot_start(pr_snapshot_start), .metadata(pr_metadata),
    .snapshot_index(pr_object_index), .snapshot_busy(pr_snapshot_busy),
    .snapshot_object(pr_object_data),
    .pix_clk(clk_pix), .pix_rst_n(rst_pix_n),
    .disp_req(disp_req), .disp_sof(disp_sof), .px(px), .py(py),
    .px_data (rdfifo_dout),
    .disp_out(ar_disp_out), .video_ready(ar_video_ready),
    .grid_rd_addr(grid_rd_addr), .grid_rd_data(grid_rd_data));

  // 阶段 4（AR）走感知核叠加结果；其余阶段保持平台原有画面
  assign disp_final = (stage_pix == `STAGE_AR) ? ar_disp_out : disp_data;

  //------------------------------------------------------------------
  // 11.5 栅格读出：把感知核的 55×60 占据栅格转成 M3TL type=5 的行优先位图
  //      grid_rd_addr 由本模块驱动、grid_rd_data 由感知核返回，
  //      两者是同一对网线（一个驱动地址、另一个驱动数据）。
  //------------------------------------------------------------------
  acx750_grid_reader u_grid (
    .clk(clk_sys), .rst_n(rst_sys_n),
    .start(grid_snapshot_start),
    .busy (grid_busy), .done(grid_done),
    .rd_addr(grid_rd_test_addr),
    .byte_out(grid_byte), .byte_valid(grid_byte_valid), .byte_index(grid_byte_index),
    .grid_rd_addr(grid_rd_addr), .grid_rd_data(grid_rd_data));

//------------------------------------------------------------------
  // 11.6 type=3 目标表：**只读监听**感知核的快照走查
  //      （走查由 perception_engine 周期发起、perception_regs 驱动
  //        的 snapshot_index 走查，本模块只旁观，不驱动这些信号，
  //        因此与 perception_regs 不冲突、无双驱动。）
  //------------------------------------------------------------------
  acx750_m3tl_targets #(
    .TARGETS_MAX   (32),
    .SEND_PERIOD_MS(1000),
    .CLK_HZ        (100_000_000)
  ) u_targets (
    .clk            (clk_sys),
    .rst_n          (rst_sys_n),
    .snapshot_start (pr_snapshot_start),
    .snapshot_busy  (pr_snapshot_busy),
    .snapshot_index (pr_object_index),
    .snapshot_object(pr_object_data),
    .metadata       (pr_metadata),
    .tgt_count      (tgt_count),
    .tgt_overflow   (tgt_overflow),
    .tgt_payload    (tgt_payload),
    .tgt_valid      (tgt_valid),
    .tgt_ack        (tgt_ack),
    .tgt_rx_cnt     (tgt_rx_cnt));

endmodule