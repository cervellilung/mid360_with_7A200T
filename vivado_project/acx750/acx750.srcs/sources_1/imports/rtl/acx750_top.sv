//============================================================================
// acx750_top -- ACX750 (XC7A200T-FBG484-2) 整机顶层
//
// 定位：把原来长在 XC7Z020 的 ARM PS 上的一切，换成 PL 自己干：
//   - 时钟全部由 MMCM 产生（板载唯一时钟源 = 50 MHz @W19）
//   - 相机从 USB UVC 改为板载 DVP（OV5640 / ACM5640-V5）
//   - 帧缓存从 PS DDR 改为板载 DDR3（MIG，32bit，1GB）
//   - 上位机从 PS TCP 改为树莓派 UDP（M3TL v1）
//   - 单网口同时承载：雷达点云接收(56301)、下行配置(56300)、遥测发送(46000)、ARP 应答
//
// 分阶段调试：一条 bitstream 走完全部阶段，用串口发 '0'..'7' 在线切换。
//   0 彩条   1 DDR3 自检   2 以太网收图→DDR3→TFT   3 OV5640→DDR3→TFT
//   4 AR 合成   5 遥测发送   6 单口分流   7 HUD 演示
// 串口同时每 500ms 打印一行：
//   S=x PLL=x DDR=x CAM=x ETH=x FRM=xxxxxxxx DRP=xxxxxxxx
//
// 状态口径：**源码已写，尚未综合/上板验证**。上板步骤见 docs/bringup_checklist.md。
//============================================================================
`timescale 1ns/1ps

`include "acx750_defs.svh"

module acx750_top #(
  parameter bit HDMI_NATIVE_600 = 1,
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

  // Board HDMI output; S0 reset, S1..S4 display controls.
  input  wire [3:0]   buttons_n,
  output wire [2:0]   hdmi_dat_p, hdmi_dat_n,
  output wire         hdmi_clk_p, hdmi_clk_n,
  output wire         hdmi_oe,

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
  wire eth_mmcm_locked, eth_locked_sys;

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
  wire        wrfifo_clk;
  wire [2:0] write_overflow;

  wire        wrfifo_clr;

  // 以太网
  wire        clk125m;
  wire        rgmii_rx_clk, gmii_rx_clk;
  wire [7:0]  gmii_rxd;
  wire        gmii_rxdv;
  wire        eth_rx_byte_valid;
  wire [7:0]  eth_rx_byte_data;
  wire        eth_pkt_done, eth_pkt_error, eth_cfg_pkt_done;
  wire [31:0] radar_source_ip;
  wire [15:0] radar_source_port, radar_payload_length;
  wire raw_udp_start, shared_udp_req;
  wire [15:0] raw_udp_length, raw_udp_port;
  wire [7:0] raw_udp_data;
  wire [31:0] raw_accepted, raw_dropped, raw_forwarded;
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
  wire clk_pix_write_raw, clk_eth_write_raw;
  wire clk_video_ref_unused, clk_hdmi_serial, hdmi_locked;
  wire [15:0] tft_rgb;
  wire tft_hs,tft_vs,tft_de,tft_clk;
  wire button_cmd_valid;
  wire [7:0] button_cmd_data;
  acx750_buttons u_buttons(.clk(clk_sys),.rst_n(rst_sys_n),
    .buttons_n(buttons_n),.stage(stage),
    .command_valid(button_cmd_valid),.command_data(button_cmd_data));
  acx750_hdmi_clocks #(.NATIVE_600(HDMI_NATIVE_600)) u_hdmi_clocks(.clk50m(clk50m),.reset_n(btn_reset_n),
    .pixel_clk(clk_pix),.serial_clk(clk_hdmi_serial),.locked(hdmi_locked));
  assign hdmi_oe = hdmi_locked && rst_pix_n;
  acx750_hdmi_tx u_hdmi_tx(.pixel_clk(clk_pix),.serial_clk(clk_hdmi_serial),
    .rst_n(rst_pix_n),.rgb565(tft_rgb),.hs(tft_hs),.vs(tft_vs),.de(tft_de),
    .hdmi_clk_p(hdmi_clk_p),.hdmi_clk_n(hdmi_clk_n),
    .hdmi_dat_p(hdmi_dat_p),.hdmi_dat_n(hdmi_dat_n));
  clk_sys_wiz u_clk_wiz (
    .clk_in1  (clk50m),
    .resetn   (btn_reset_n),
    .clk_out1 (clk200),
    .clk_out2 (clk_sys),
    .clk_out3 (clk_video_ref_unused),
    .clk_out4 (clk_camxclk),
    .clk_out5 (clk_pix_write_raw),
    .locked   (pll_locked)
  );

  assign cam_xclk = clk_camxclk;

  //========================================================================
  // 3. 复位
  //========================================================================
  acx750_reset #(.DEBOUNCE_CLK(1_000_000)) u_rst_sys (
    .clk(clk_sys), .locked(pll_locked),
    .btn_reset_n(btn_reset_n), .rst_n(rst_sys_n));

  xpm_cdc_async_rst #(.DEST_SYNC_FF(2),.INIT_SYNC_FF(1),.RST_ACTIVE_HIGH(0)) u_rst_pix (
    .src_arst(rst_sys_n && hdmi_locked),.dest_clk(clk_pix),.dest_arst(rst_pix_n));

  // 以太网逻辑要等 DDR3 校准完再放开（与厂商 ch57 一致）
  assign rst_eth_ok = rst_sys_n && ddr3_init_done && eth_mmcm_locked;

  //========================================================================
  // 4. 阶段控制 + 串口
  //========================================================================
  acx750_uart_rx #(.CLK_HZ(100_000_000), .BAUD(115_200)) u_uart_rx (
    .clk(clk_sys), .rst_n(rst_sys_n), .rxd(uart_rxd),
    .rx_data(uart_rx_byte), .rx_data_valid(uart_rx_valid));

  acx750_cmd #(.STARTUP_STAGE(STARTUP_STAGE)) u_cmd (
    .clk(clk_sys), .rst_n(rst_sys_n),
    .rx_valid(uart_rx_valid || button_cmd_valid),
    .rx_data(button_cmd_valid ? button_cmd_data : uart_rx_byte),
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
  assign led[1] = pll_locked && eth_locked_sys;         // MMCM 锁定
  assign led[2] = ddr3_init_done;     // DDR3 校准完成
  assign led[3] = eth_rx_activity;    // 网口有帧

  acx750_uart_report #(.CLK_HZ(100_000_000), .BAUD(115_200), .PERIOD_MS(500)) u_report (
    .clk(clk_sys), .rst_n(rst_sys_n),
    .stage(stage),
    .pll_locked(pll_locked && eth_locked_sys),
    .ddr3_done(ddr3_init_done),
    .cam_done(cam_init_done),
    .eth_up(eth_rx_activity),
    .frame_cnt(frame_cnt),
    .drop_cnt(drop_cnt),
    .txd(uart_txd));

  //========================================================================
  // 6. 显示：时序发生器 + 像素源 + HUD
  //========================================================================
  acx750_cdc_snapshot #(.WIDTH(3),.RESET_VALUE(STARTUP_STAGE)) u_stage_pixel (
    .src_clk(clk_sys),.src_rst_n(rst_sys_n),.src_data(stage),
    .dest_clk(clk_pix),.dest_rst_n(rst_pix_n),.dest_data(stage_pix));
  logic video_ready_sys;
  wire video_ready_pix;
  always_ff @(posedge clk_sys or negedge rst_sys_n)
    if(!rst_sys_n) video_ready_sys<=1'b0;
    else video_ready_sys<=ddr3_init_done && !stage_busy;
  xpm_cdc_single #(.DEST_SYNC_FF(2),.INIT_SYNC_FF(1),.SRC_INPUT_REG(0)) u_video_ready (
    .src_clk(clk_sys),.src_in(video_ready_sys),
    .dest_clk(clk_pix),.dest_out(video_ready_pix));


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

  acx750_hdmi_canvas #(.NATIVE_600(HDMI_NATIVE_600),.AHEAD_CLK_CNT(AHEAD_CLK_CNT)) u_disp (
    .ClkDisp    (clk_pix),
    .Rst_n      (rst_pix_n),
    .Data       (disp_data),
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

  // TFT connector is no longer driven. Former tft_pwm = 1'b1;              // 背光常亮

  acx750_hud_text #(.CLK_HZ(100_000_000), .REFRESH_MS(250)) u_hud_text (
    .clk(clk_sys), .rst_n(rst_sys_n),
    .stage(stage),
    .pll_locked(pll_locked && eth_locked_sys), .ddr3_done(ddr3_init_done),
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
    .cam_dout(rdfifo_dout),             // 摄像头同样经帧缓存，不经直通
    .hud_txt_addr(hud_txt_addr), .hud_txt_data(hud_txt_data),
    .data(disp_data));

  //========================================================================
  // 7. DDR3 帧缓存
  //========================================================================
  // 写时钟三选一（无毛刺 BUFGMUX 级联）。sel 只在 stage_hold 的后半段翻转，
  // 保证切换发生在 wrfifo 处于异步复位期间，不会产生半个写脉冲。
  // Fixed system-clock DDR writes via three independent BRAM FIFOs.
  assign wrfifo_clk = clk_sys;
  // Display modes CAMERA and AR share the live OV5640 DDR write source.
  wire [2:0] write_source_stage = (stage == `STAGE_AR) ? `STAGE_CAMERA : stage;
  acx750_write_bridge u_write_bridge (
    .sys_clk(clk_sys), .rst_n(rst_sys_n), .flush(stage_busy), .stage(write_source_stage),
    .pix_clk(clk_pix), .pix_valid(pat_wren), .pix_data(pat_rgb),
    .eth_clk(clk125m), .eth_valid(eth_img_wren), .eth_data(eth_img_data),
    .cam_clk(cam_pclk_bufg), .cam_valid(cam_wren), .cam_data(cam_data_pix),
    .out_ready(!wrfifo_full && ddr3_init_done),
    .out_valid(bridge_valid), .out_data(wrfifo_din), .overflow(write_overflow)
  );
  wire bridge_valid;
  assign wrfifo_wren = bridge_valid && !wrfifo_full && ddr3_init_done;

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

      cmp_en <= (stage_pix == `STAGE_DDR3_SELF) && video_ready_pix;
      if ((stage_pix == `STAGE_DDR3_SELF) && video_ready_pix)
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
  // Factory ch52 RX clock topology: internal feedback, BUFG at MMCM output.
  eth_phase_mmcm u_eth_mmcm (
    .clk_in1(eth_rx_clk), .clk_out1(rgmii_rx_clk),
    .reset(~rst_sys_n), .locked(eth_mmcm_locked));

  // Observe RX clock lock without crossing an asynchronous status bit.
  xpm_cdc_single #(.DEST_SYNC_FF(2),.INIT_SYNC_FF(1),.SRC_INPUT_REG(0))
    u_eth_lock_status (.src_clk(1'b0), .src_in(eth_mmcm_locked),
      .dest_clk(clk_sys), .dest_out(eth_locked_sys));

  // IDDR uses the factory MMCM output; decoder BUFG is preserved as in ch52.
  rgmii_to_gmii u_rgmii2gmii (
    .reset_n     (rst_eth_n),
    .gmii_rx_clk (gmii_rx_clk),
    .gmii_rxd    (gmii_rxd),
    .gmii_rxdv   (gmii_rxdv),
    .gmii_rxerr  (),
    .rgmii_rx_clk(rgmii_rx_clk),
    .rgmii_rxd   (eth_rxd),
    .rgmii_rxdv  (eth_rx_dv));

  // 流 0：雷达点云（MID-360 -> PL:56301）。
  // 注意 eth_udp_rx_gmii 的 gmii_rx_clk 必须是 MMCM 原始输出（内部还会 BUFG）
  eth_udp_rx_gmii u_udp_pts (
    .reset          (~rst_eth_n),
    .local_mac      (`PL_MAC),
    .local_ip       (`PL_IP),
    .local_port     (`RADAR_PORT),
    .clk125m_o      (clk125m),               // BUFG 后的 125 MHz，全网口逻辑用它
    .exter_mac      (),
    .exter_ip       (radar_source_ip),
    .exter_port     (radar_source_port),
    .rx_data_length (radar_payload_length),
    .data_overflow_i(1'b0),
    .payload_valid_o(eth_rx_byte_valid),
    .payload_dat_o  (eth_rx_byte_data),
    .one_pkt_done   (eth_pkt_done),
    .pkt_error      (eth_pkt_error),
    .debug_crc_check(),
    .gmii_rx_clk    (rgmii_rx_clk),
    .gmii_rxd       (gmii_rxd),
    .gmii_rxdv      (gmii_rxdv));

  // 流 1：上位机下行配置（树莓派 -> PL:56300）本轮**不例化**。
  //
  // 原因（重要，别随手加回来）：厂商 eth_udp_rx_gmii **内部自带
  // `BUFG BUFG_pclk(.I(gmii_rx_clk), ...)`**。如果同时例化两个实例，
  // 就会有**两个 BUFG 挂在同一个 MMCM 输出脚上**——7 系列的 MMCM 输出
  // 只能经专用布线驱动一个 BUFG，第二个会直接导致实现阶段报错。
  // 仓库里 rtl/vendor_ref/eth_rx/eth_udp_rx_gmii.v 是厂商原文，我们不改它。
  //
  // 后续要收下行配置时，二选一：
  //   (a) 改 ip/eth_phase_mmcm.xci，让它多出一路 125 MHz 输出（同一 MMCM
  //       的 CLKOUT1），两路各驱动一个 BUFG；
  //   (b) 自己写一个不带内部 BUFG 的 UDP 接收器，或把厂商那份的 BUFG 去掉
  //       （那就是"已修改厂商原文"，必须在 docs/vendor_sources.md 登记）。
  // 详见 docs/known_gaps.md。

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
  // 12-bit/2048-sample on-board capture; no functional datapath latency.
  ila_net u_net_ila (.clk(clk125m),
    .probe0({arp_start, eth_pkt_done, rst_eth_n, gmii_rxdv, gmii_rxd}),
    .probe1({raw_accepted,raw_dropped,raw_forwarded}));
  assign eth_rx_activity = (act_cnt != '0);

  always_ff @(posedge clk125m or negedge rst_eth_n) begin
    if (!rst_eth_n) rx_pkt_cnt_eth <= 32'd0;
    else if (eth_pkt_done) rx_pkt_cnt_eth <= rx_pkt_cnt_eth + 32'd1;
  end

  // PHY 复位与 MDIO
  phy_reg_config #(
    .speed     (2'b10),                 // 百兆起步，与厂商一致
    .SYS_CLOCK (100_000_000),
    .MDC_CLOCK (1_000_000),
    .MAX_CNT   (3)
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

  acx750_m3tl_tx #(.CLK_HZ(125_000_000), .HB_PERIOD_MS(500), .CAM_PERIOD_MS(1000)) u_m3tl (
    .clk125m    (clk125m),
    .rst_n      (rst_eth_n),
    .stat_flags ({3'b0, (|write_overflow), cam_init_done, eth_rx_activity, ddr3_init_done, pll_locked}),
    .stage      (stage),
    .uptime_ms  (uptime_ms),
    .drop_count (drop_cnt),
    .cam_frames (cam_pix_cnt),
    .cam_last_ms(32'd0),
    .cam_width  (`DISP_WIDTH),
    .cam_height (`DISP_HEIGHT),
    .dst_mac    (telem_dst_mac),
    .dst_ip     (`HOST_IP),
    .tx_start   (m3tl_start),
    .tx_len     (m3tl_len),
    .tx_req     (m3tl_req),
    .tx_payload (m3tl_payload),
    .tx_busy    (m3tl_busy),
    .tx_pkt_cnt (m3tl_pkt_cnt));

  acx750_raw_forward u_raw_forward (
    .clk(clk125m),.rst_n(rst_eth_n),
    .rx_valid(eth_rx_byte_valid),.rx_data(eth_rx_byte_data),
    .rx_done(eth_pkt_done),.rx_error(eth_pkt_error),.rx_length(radar_payload_length),
    .rx_source_ip(radar_source_ip),.rx_source_port(radar_source_port),
    .telemetry_start(m3tl_start),.telemetry_length(m3tl_len),
    .telemetry_data(m3tl_payload),.telemetry_req(m3tl_req),
    .udp_start(raw_udp_start),.udp_length(raw_udp_length),.udp_port(raw_udp_port),
    .udp_data(raw_udp_data),.udp_req(shared_udp_req),.udp_busy(arb_p1_busy),
    .accepted(raw_accepted),.dropped(raw_dropped),.forwarded(raw_forwarded));

  acx750_eth_tx_arb u_tx_arb (
    .clk125m    (clk125m),
    .rst_n      (rst_eth_n),
    .p0_start   (arp_start),
    .p0_len     (arp_len),
    .p0_idx     (arp_idx),
    .p0_val     (arp_val),
    .p0_busy    (arp_busy),
    .p1_start   (raw_udp_start),
    .p1_len     (raw_udp_length),
    .p1_dst_mac (telem_dst_mac),
    .p1_src_mac (`PL_MAC),
    .p1_dst_ip  (`HOST_IP),
    .p1_src_ip  (`PL_IP),
    .p1_dst_port(raw_udp_port),
    .p1_src_port(`RADAR_PORT),
    .p1_req     (shared_udp_req),
    .p1_payload (raw_udp_data),
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
  // Match the vendor DDR-ready startup, with synchronous release in each domain.
  wire rst_cam_init_n;
  acx750_rst_sync u_rst_cam_init(.clk(clk_sys),
    .arst_n(rst_sys_n && ddr3_init_done),.rst_n(rst_cam_init_n));
  BUFG u_cam_bufg (.I(cam_pclk), .O(cam_pclk_bufg));

  acx750_rst_sync u_rst_cam (.clk(cam_pclk_bufg), .arst_n(rst_cam_init_n), .rst_n(rst_cam_n));

  camera_init #(
    .SYS_CLOCK(100_000_000),
    .CAMERA_TYPE    ("ov5640"),
    .IMAGE_TYPE     (0),                // RGB（不是 JPEG）
    .IMAGE_WIDTH    (`DISP_WIDTH),
    .IMAGE_HEIGHT   (`DISP_HEIGHT),
    .IMAGE_FLIP_EN  (0),
    .IMAGE_MIRROR_EN(0)
  ) u_cam_init (
    .Clk         (clk_sys),
    .Rst_n       (rst_cam_init_n),
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
  acx750_cdc_snapshot #(.WIDTH(32)) u_sync_frm (
    .src_clk(clk_pix),.src_rst_n(rst_pix_n),.src_data(frame_cnt_pix),
    .dest_clk(clk_sys),.dest_rst_n(rst_sys_n),.dest_data(frame_cnt));

  acx750_cdc_snapshot #(.WIDTH(32)) u_sync_drp (
    .src_clk(clk_pix),.src_rst_n(rst_pix_n),.src_data(mismatch_cnt),
    .dest_clk(clk_sys),.dest_rst_n(rst_sys_n),.dest_data(drop_cnt));

  acx750_sync_word #(.WIDTH(32)) u_sync_cam (
    .clk(clk_sys), .rst_n(rst_sys_n), .d(cam_wr_cnt),    .q(cam_pix_cnt));

  acx750_sync_word #(.WIDTH(32)) u_sync_arp (
    .clk(clk_sys), .rst_n(rst_sys_n), .d(arp_req_cnt),   .q(pts_pkt_cnt));

  acx750_sync_word #(.WIDTH(32)) u_sync_bad (
    .clk(clk_sys), .rst_n(rst_sys_n), .d(arp_rsp_cnt),   .q(rx_bad_cnt));

  acx750_sync_word #(.WIDTH(32)) u_sync_rxp (
    .clk(clk_sys), .rst_n(rst_sys_n), .d(rx_pkt_cnt_eth), .q(rx_pkt_cnt_sys));

endmodule