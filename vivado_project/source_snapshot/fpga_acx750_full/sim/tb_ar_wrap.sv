//============================================================================
// tb_ar_wrap -- acx750_ar_wrap / acx750_raster_axis 自检测试台
//
// 验证 4 件事：
//   1) 透传正确性：给一帧已知图案（默认 cfg、无目标框），检查 disp_out 与
//      输入图案逐像素一致，允许一个全局延迟 L（同时把 L 测出来）。
//      注：ar_video 的 HUD 固定绘制在左上角（py∈[8,22) 且 px∈[8,272) 的
//      若干字符格），这是感知核的既定行为、不属于"透传"。故比对时排除该
//      区域；区域外必须逐像素一致。
//   2) 测出 perception_engine(含 ar_video) 的 s→m 延迟 L（拍）：
//      - 用"唯一探针像素"直接测加载拍数；
//      - 用 0..7 拍输入历史做逐像素比对，只有正确的 L 才会 0 失配。
//   3) 反压：out_ready 恒 1 时，video_ready(=ar_video.s_ready) 是否恒 1。
//   4) 帧同步：连续 3 帧，video_sof 每帧 1 次、video_eol 每行 1 次、
//      每帧 800*480 个 valid（在适配器输出侧与引擎输出侧分别统计）。
//
// 判定：输出 PASS / FAIL。工具：Vivado 2018.3 xvlog/xelab/xsim。
//============================================================================
`timescale 1ns/1ps

module tb_ar_wrap;

  localparam integer W = 800;
  localparam integer H = 480;
  localparam integer FRAMES = 3;

  //--------------------------------------------------------------------------
  // 时钟：控制域 50 MHz，像素域 100 MHz（延迟以像素拍为单位，与频率无关）
  //--------------------------------------------------------------------------
  logic clk = 0, pix_clk = 0;
  always #10 clk     = ~clk;       // 20 ns
  always #5  pix_clk = ~pix_clk;   // 10 ns

  //--------------------------------------------------------------------------
  // 复位（低有效）
  //--------------------------------------------------------------------------
  logic rst_n = 0, pix_rst_n = 0;

  //--------------------------------------------------------------------------
  // dut 输入
  //--------------------------------------------------------------------------
  logic [63:0]   now_us       = 64'd0;
  logic [7:0]    radar_data   = 8'd0;
  logic          radar_valid  = 1'b0, radar_last = 1'b0;
  logic [7:0]    odom_data    = 8'd0;
  logic          odom_valid   = 1'b0, odom_last  = 1'b0;
  logic [31:0]   s_fo = 0, s_er = 0, s_ob = 0, s_obu = 0, s_rd = 0, s_cd = 0;
  logic [2047:0] cfg          = 2048'd0;   // 默认：无目标框、非 test_mode、非 stereo
  logic [7071:0] lut          = 7072'd0;
  logic          cfg_pending  = 1'b0;
  logic [4:0]    snap_index   = 5'd0;
  logic          snap_busy    = 1'b0;

  logic          disp_req = 0, disp_sof = 0;
  logic [11:0]   px = 0, py = 0;
  logic [15:0]   px_data = 0;

  //--------------------------------------------------------------------------
  // dut 输出
  //--------------------------------------------------------------------------
  logic          cfg_safe, snapshot_start, video_ready;
  logic [1023:0] metadata;
  logic [383:0]  snapshot_object;
  logic [15:0]   disp_out;

  acx750_ar_wrap dut (
    .clk                      (clk),
    .rst_n                    (rst_n),
    .now_us                   (now_us),
    .radar_data               (radar_data),
    .radar_valid              (radar_valid),
    .radar_last               (radar_last),
    .odom_data                (odom_data),
    .odom_valid               (odom_valid),
    .odom_last                (odom_last),
    .src_fifo_overflow        (s_fo),
    .src_eth_rejected         (s_er),
    .src_odom_bad             (s_ob),
    .src_odom_busy            (s_obu),
    .src_radar_slot_drops     (s_rd),
    .src_chassis_slot_drops   (s_cd),
    .cfg                      (cfg),
    .lut                      (lut),
    .cfg_pending              (cfg_pending),
    .cfg_safe                 (cfg_safe),
    .snapshot_start           (snapshot_start),
    .metadata                 (metadata),
    .snapshot_index           (snap_index),
    .snapshot_busy            (snap_busy),
    .snapshot_object          (snapshot_object),
    .pix_clk                  (pix_clk),
    .pix_rst_n                (pix_rst_n),
    .disp_req                 (disp_req),
    .disp_sof                 (disp_sof),
    .px                       (px),
    .py                       (py),
    .px_data                  (px_data),
    .disp_out                 (disp_out),
    .video_ready              (video_ready)
  );

  //--------------------------------------------------------------------------
  // 已知图案：唯一探针 (400,200)->0xA5A5；其余 = x*17+y（< 0x8000，不冲突）
  //--------------------------------------------------------------------------
  function automatic [15:0] pat (input integer x, input integer y);
    begin
      if (x == 400 && y == 200)
        pat = 16'hA5A5;
      else
        pat = (x * 17 + y) & 16'h7FFF;
    end
  endfunction

  // HUD 固定绘制区（ar_video: px>=8 && py>=8 && py<22）。COMPACT_HUD 下被点亮的
  // 字符格为 0,1,3..8("D:-xxxxM") 与 20,21,22("R:<risk>")，最远的 char22 落在
  // hud_x∈[264,275] → px∈[272,283]。故排除 px∈[8,288) 整段最稳妥。
  function automatic logic is_hud (input integer x, input integer y);
    begin
      is_hud = (y >= 8 && y < 22 && x >= 8 && x < 288);
    end
  endfunction

  //--------------------------------------------------------------------------
  // 监测：posedge 读"本拍(cycle t)"的输入与输出
  //   - 输入在 negedge 驱动，posedge 时稳定；
  //   - 输出寄存器在 posedge 做 NBA 更新，故本块的读值即 cycle t 值。
  //   维护 8 拍输入历史，之后 out(t) 应与 in(t-L) 一致。
  //--------------------------------------------------------------------------
  logic [15:0] h_d [0:7];
  logic [11:0] h_x [0:7], h_y [0:7];
  logic        h_v [0:7], h_s [0:7], h_e [0:7];
  integer      match [0:7], mism [0:7];

  integer i, L;
  integer cycles, s_probe, o_probe;
  integer bp_zero;
  integer val_m, sof_m, eol_m;
  integer val_a, sof_a, eol_a;
  integer dbg_n;
  integer mm_data, mm_flag;   // L=1 失配中：数据不同 / sof-eol 标志不同

  always @(posedge pix_clk) begin
    if (pix_rst_n) begin
      cycles = cycles + 1;

      // 移位历史：h[0] <- 本拍输入
      for (i = 7; i > 0; i = i - 1) begin
        h_d[i] = h_d[i-1]; h_x[i] = h_x[i-1]; h_y[i] = h_y[i-1];
        h_v[i] = h_v[i-1]; h_s[i] = h_s[i-1]; h_e[i] = h_e[i-1];
      end
      h_d[0] = px_data; h_x[0] = px; h_y[0] = py;
      h_v[0] = disp_req;
      h_s[0] = disp_req && (px == 12'd0)  && (py == 12'd0);
      h_e[0] = disp_req && (px == 12'd799);

      // 输出侧统计（引擎 m 口）
      if (dut.u_engine.out_valid) begin
        val_m = val_m + 1;
        if (dut.u_engine.out_sof) sof_m = sof_m + 1;
        if (dut.u_engine.out_eol) eol_m = eol_m + 1;
      end
      // 反压统计：engine 的 s_ready
      if (!dut.video_ready) bp_zero = bp_zero + 1;

      // 适配器输出侧统计
      val_a = val_a + (dut.u_raster.video_valid ? 1 : 0);
      sof_a = sof_a + (dut.u_raster.video_sof   ? 1 : 0);
      eol_a = eol_a + (dut.u_raster.video_eol   ? 1 : 0);

      // 逐像素比对：out(t) 对 in(t-L)，排除 HUD 固定区
      if (dut.u_engine.out_valid) begin
        for (L = 0; L < 8; L = L + 1) begin
          if (h_v[L] && !is_hud(h_x[L], h_y[L])) begin
            if ((dut.disp_out        === h_d[L]) &&
                (dut.u_engine.out_sof === h_s[L]) &&
                (dut.u_engine.out_eol === h_e[L]))
              match[L] = match[L] + 1;
            else begin
              mism[L] = mism[L] + 1;
              if (L == 1) begin
                if (dut.disp_out !== h_d[L]) mm_data = mm_data + 1;
                if (dut.u_engine.out_sof !== h_s[L] ||
                    dut.u_engine.out_eol !== h_e[L]) mm_flag = mm_flag + 1;
                if (dbg_n < 24) begin
                  $display("  [mism L=1] t=%0t px=%0d py=%0d exp=%04h got=%04h exps=%0b gots=%0b expe=%0b gote=%0b",
                           $time, h_x[L], h_y[L], h_d[L], dut.disp_out,
                           h_s[L], dut.u_engine.out_sof, h_e[L], dut.u_engine.out_eol);
                  dbg_n = dbg_n + 1;
                end
              end
            end
          end
        end
      end

      // 唯一探针像素的加载拍数
      if (disp_req && (px == 12'd400) && (py == 12'd200) && (s_probe < 0))
        s_probe = cycles;
      if (dut.u_engine.out_valid && (dut.disp_out === 16'hA5A5) && (o_probe < 0))
        o_probe = cycles;
    end
  end

  //--------------------------------------------------------------------------
  // 驱动：negedge 更新输入，保证 posedge 采样无竞争
  //--------------------------------------------------------------------------
  task automatic drive_pixel (input integer x, input integer y);
    begin
      @(negedge pix_clk);
      px       = x[11:0];
      py       = y[11:0];
      disp_req = 1'b1;
      disp_sof = 1'b0;
      px_data  = pat(x, y);
    end
  endtask

  // 帧间消隐：disp_req 拉低、发一个 disp_sof（验证它不会误产生 video_sof）
  task automatic frame_gap;
    begin
      @(negedge pix_clk);
      disp_req = 1'b0; disp_sof = 1'b1;
      px = 12'd0; py = 12'd0; px_data = 16'd0;
      @(negedge pix_clk);
      disp_sof = 1'b0;
    end
  endtask

  //--------------------------------------------------------------------------
  // 结果判定与打印
  //--------------------------------------------------------------------------
  task automatic report_and_check;
    integer ok, chosen_L, exp_valid, exp_sof, exp_eol;
    begin
      ok       = 1;
      chosen_L = -1;
      for (L = 0; L < 8; L = L + 1)
        if (match[L] > 0 && mism[L] == 0) chosen_L = L;

      exp_valid = FRAMES * W * H;
      exp_sof   = FRAMES;
      exp_eol   = FRAMES * H;

      $display("==== tb_ar_wrap 实测结果 ====");
      $display("s->m 延迟探针: s_probe=%0d o_probe=%0d  L=%0d (像素拍)",
               s_probe, o_probe, o_probe - s_probe);
      $display("逐像素比对(非HUD区) per-L: ");
      for (L = 0; L < 8; L = L + 1)
        $display("    L=%0d : match=%0d mism=%0d", L, match[L], mism[L]);
      $display("判定的延迟 L = %0d", chosen_L);
      $display("帧同步(引擎输出侧): valid=%0d sof=%0d eol=%0d (期望 %0d/%0d/%0d)",
               val_m, sof_m, eol_m, exp_valid, exp_sof, exp_eol);
      $display("帧同步(适配器侧)  : valid=%0d sof=%0d eol=%0d", val_a, sof_a, eol_a);
      $display("video_ready==0 的像素拍数 = %0d (out_ready 恒 1)", bp_zero);
      $display("L=1 失配细分: 数据不同=%0d, sof/eol 标志不同=%0d", mm_data, mm_flag);

      if (!(o_probe >= 0 && s_probe >= 0 && (o_probe - s_probe) == 1)) begin
        $display("FAIL: 延迟探针未测到 L=1"); ok = 0;
      end
      if (chosen_L != 1) begin
        $display("FAIL: 逐像素比对得到的 L=%0d，不是 1", chosen_L); ok = 0;
      end
      if (mism[1] != 0) begin
        $display("FAIL: L=1 存在 %0d 个失配像素", mism[1]); ok = 0;
      end
      if (match[1] == 0) begin
        $display("FAIL: 没有任何像素被比对"); ok = 0;
      end
      if (val_m != exp_valid || sof_m != exp_sof || eol_m != exp_eol) begin
        $display("FAIL: 引擎侧帧同步计数不符"); ok = 0;
      end
      if (val_a != exp_valid || sof_a != exp_sof || eol_a != exp_eol) begin
        $display("FAIL: 适配器侧帧同步计数不符"); ok = 0;
      end
      if (bp_zero != 0) begin
        $display("FAIL: video_ready 出现过 0（%0d 拍）", bp_zero); ok = 0;
      end

      if (ok)
        $display("PASS tb_ar_wrap: 透传逐像素一致(L=1)、帧同步正确、无反压");
      else
        $display("FAIL tb_ar_wrap");
    end
  endtask

  //--------------------------------------------------------------------------
  // 主流程
  //--------------------------------------------------------------------------
  integer f, xx, yy;
  initial begin
    for (i = 0; i < 8; i = i + 1) begin
      h_d[i] = 16'd0; h_x[i] = 12'd0; h_y[i] = 12'd0;
      h_v[i] = 1'b0; h_s[i] = 1'b0; h_e[i] = 1'b0;
      match[i] = 0; mism[i] = 0;
    end
    cycles = 0; s_probe = -1; o_probe = -1; bp_zero = 0;
    val_m = 0; sof_m = 0; eol_m = 0;
    val_a = 0; sof_a = 0; eol_a = 0;
    dbg_n = 0; mm_data = 0; mm_flag = 0;

    // 复位
    rst_n = 1'b0; pix_rst_n = 1'b0;
    #50;
    rst_n = 1'b1;
    pix_rst_n = 1'b1;
    repeat (4) @(negedge pix_clk);

    // 连续送 FRAMES 帧完整光栅（800x480）
    for (f = 0; f < FRAMES; f = f + 1) begin
      for (yy = 0; yy < H; yy = yy + 1)
        for (xx = 0; xx < W; xx = xx + 1)
          drive_pixel(xx, yy);
      frame_gap;
    end
    repeat (16) @(negedge pix_clk);

    report_and_check;
    $finish;
  end

  // 看门狗
  initial begin
    #200_000_000;
    $display("FAIL tb_ar_wrap: 超时");
    $finish;
  end

endmodule