//============================================================================
// acx750_m3tl_targets -- 旁路监听感知引擎的目标快照走查，打包成 M3TL type=3 表
//
// 设计依据、字段映射出处与顶层接法见 docs/m3tl_targets_750.md。
//
// 【路线 A：旁路监听（tap），零修改他人】
//   perception_regs 已经在"走查"目标表：它驱动 snapshot_index=copy_index 0..31、
//   每个时钟锁存一条 snapshot_object，把 32 个目标存进自己的快照区。
//   perception_engine 在 grid_pulse / 里程更新 / 10 ms 看门狗驱动下，会**周期性地**
//   发起 snapshot_start（详见 perception_engine.sv 第 95、99、103、110 行），因此
//   平时就有走查（>=100 Hz），无需我们再造一个发起源。据此本模块只**只读监听**
//   snapshot_busy / snapshot_index / snapshot_object / metadata，不动任何快照接口，
//   与 perception_regs 并行、互不冲突（不会双驱动）。
//
// 【设计依据：snapshot_object[383:0] 到底是什么字段】
//   snapshot_object = perception 的 object_t（packed struct，首个成员在 MSB）：
//     [383:368]=cells  [367:352]=points
//     [351:320]=x0     [319:288]=y0     [287:256]=z0
//     [255:224]=x1     [223:192]=y1     [191:160]=z1
//     [159:96] =d2     [95:64]  =cx     [63:32]  =cy   [31:0]=cz
//   其中 x0/y0/z0 = 包围盒最小角、x1/y1/z1 = 最大角，d2 = 最近点的 x^2+y^2(mm^2)。
//   出处：
//     * perception_types.svh 第 16..21 行 object_t 定义（首个成员在 MSB）；
//     * lidar_grid.sv 第 76..82/144..151 行：region.x0 取 min、x1 取 max；
//     * perception_regs.sv 第 78 行 snapshot[32+i*12+j] <- object_data[(11-j)*32+:32]
//       （把整字序反演，印证字 0 = {cells,points} ... 字 11 = cz）。
//
// 【输出记录（协议 docs/telemetry_protocol.md 第 24..26 行）】
//   id:u8=走查下标, flags:u8=0, x_min/x_max = x0/x1, y_min/y_max = y0/y1,
//   z_min/z_max = z0/z1（均饱和到 i16）, nearest_mm:u16 = floor(sqrt(d2))。
//
// 【tgt_payload 位宽】
//   任务书原写 [511:0]，但"4 字节头 + 32×16 字节 = 516 字节 = 4128 bit"，
//   512 bit 物理上装不下；任务书亦允许加宽。本实现按 (4+TARGETS_MAX*16) 字节
//   导出（TARGETS_MAX=32 → [4127:0]）。已在报告与文档说明。
//============================================================================
`timescale 1ns/1ps

module acx750_m3tl_targets #(
  parameter int unsigned TARGETS_MAX    = 32,
  parameter int unsigned SEND_PERIOD_MS = 1000,
  parameter int unsigned CLK_HZ         = 100_000_000
)(
  input  logic         clk,
  input  logic         rst_n,

  // ---- 只读监听感知引擎的快照走查（不要驱动这些信号）----
  input  logic         snapshot_start,        // 本模块不使用（走查以 snapshot_busy 判定）
  input  logic         snapshot_busy,
  input  logic [4:0]   snapshot_index,
  input  logic [383:0] snapshot_object,
  input  logic [1023:0] metadata,             // 目标数在 metadata[69:64]（6 bit）

  // ---- 目标表输出（给 M3TL 发送器）----
  output logic [7:0]   tgt_count,             // 本包目标数（<=32）
  output logic [7:0]   tgt_overflow,          // 溢出标志（目标数达到上限）
  output logic [(4+TARGETS_MAX*16)*8-1:0] tgt_payload,  // 4B 头 + 32×16B
  output logic         tgt_valid,             // 表就绪（保持到 tgt_ack，见文档）
  input  logic         tgt_ack,               // 发送器已取走
  output logic [31:0]  tgt_rx_cnt             // 收到多少次可用快照（完成走查次数）
);

  localparam int unsigned TGT_BYTES = 4 + TARGETS_MAX*16;   // 516
  localparam logic [5:0]  TGT_MAX_C = TARGETS_MAX;         // 目标数上限（6bit 视图）

  //==========================================================================
  // 0. 组合：当前 snapshot_object 的字段（object_t packed struct 字序）
  //==========================================================================
  wire signed [31:0] o_x0 = snapshot_object[351:320];
  wire signed [31:0] o_y0 = snapshot_object[319:288];
  wire signed [31:0] o_z0 = snapshot_object[287:256];
  wire signed [31:0] o_x1 = snapshot_object[255:224];
  wire signed [31:0] o_y1 = snapshot_object[223:192];
  wire signed [31:0] o_z1 = snapshot_object[191:160];
  wire        [63:0] o_d2 = snapshot_object[159:96];

  wire [5:0] meta_count = metadata[69:64];   // lidar_grid object_count

  // 有符号饱和到 i16（协议记录字段为 i16）
  function automatic logic [15:0] sat16(input logic signed [31:0] v);
    if (v > 32'sd32767)       sat16 = 16'h7FFF;
    else if (v < -32'sd32768) sat16 = 16'h8000;
    else                      sat16 = v[15:0];
  endfunction

  // 饱和后的记录字段（先算好，避免对函数返回值再做位选）
  wire [15:0] w_x0 = sat16(o_x0);
  wire [15:0] w_x1 = sat16(o_x1);
  wire [15:0] w_y0 = sat16(o_y0);
  wire [15:0] w_y1 = sat16(o_y1);
  wire [15:0] w_z0 = sat16(o_z0);
  wire [15:0] w_z1 = sat16(o_z1);

  //==========================================================================
  // 1. 1 ms 时基（与 acx750_m3tl_full_tx 同法）
  //==========================================================================
  localparam logic [23:0] TICK_DIV = CLK_HZ / 1000;
  logic [23:0] tick_cnt;
  logic        tick_ms;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tick_cnt <= 24'd0;
      tick_ms  <= 1'b0;
    end else if (tick_cnt == TICK_DIV - 24'd1) begin
      tick_cnt <= 24'd0;
      tick_ms  <= 1'b1;
    end else begin
      tick_cnt <= tick_cnt + 24'd1;
      tick_ms  <= 1'b0;
    end
  end

  logic [31:0] ms_cnt;
  logic        tgt_clr;
  wire         send_due = (ms_cnt >= SEND_PERIOD_MS);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ms_cnt <= 32'd0;
    end else if (tgt_clr) begin
      ms_cnt <= 32'd0;
    end else if (tick_ms && (ms_cnt < SEND_PERIOD_MS)) begin
      ms_cnt <= ms_cnt + 32'd1;
    end
  end

  //==========================================================================
  // 2. 打包缓冲（516 字节）：无复位（便于推断为寄存器/LUTRAM）
  //      [0..3]       头：count, overflow, reserved:u16
  //      [4+i*16+m]   第 i 条记录第 m 字节
  //==========================================================================
  logic [7:0]  payload_b [0:TGT_BYTES-1];
  logic [31:0] d2_mem    [0:TARGETS_MAX-1];

  //==========================================================================
  // 3. 整数平方根（恢复余数法，16 步，输入 32bit 非负，输出 floor(sqrt)）
  //==========================================================================
  logic [5:0]  sq_i;
  logic [4:0]  sq_step;
  logic        sq_run;
  logic [31:0] sq_root, sq_bit, sq_rem;

  wire [31:0] sq_sum    = sq_root + sq_bit;
  wire        sq_ge     = (sq_rem >= sq_sum);
  wire [31:0] sq_root_n = sq_ge ? ((sq_root >> 1) + sq_bit) : (sq_root >> 1);
  wire [31:0] sq_rem_n  = sq_ge ? (sq_rem - sq_sum) : sq_rem;

  //==========================================================================
  // 4. 主状态机
  //==========================================================================
  typedef enum logic [1:0] {
    S_IDLE    = 2'd0,
    S_CAPTURE = 2'd1,   // 走查进行中（旁路抓取，见下方采样逻辑）
    S_SQRT    = 2'd2,   // 逐条补算 nearest_mm
    S_PRESENT = 2'd3    // 表就绪，保持到 tgt_ack
  } tst_e;

  tst_e        st;
  logic [5:0]  cap_count;       // 本次走查目标数（0..32）
  logic        have_new;        // 有新表待发
  logic [7:0]  pub_count, pub_overflow;
  logic        tgt_valid_r;

  wire cap_en = (st == S_IDLE) || (st == S_CAPTURE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st           <= S_IDLE;
      cap_count    <= 6'd0;
      have_new     <= 1'b0;
      pub_count    <= 8'd0;
      pub_overflow <= 8'd0;
      tgt_valid_r  <= 1'b0;
      tgt_clr      <= 1'b0;
      tgt_rx_cnt   <= 32'd0;
      sq_i         <= 6'd0;
      sq_step      <= 5'd0;
      sq_run       <= 1'b0;
      sq_root      <= 32'd0;
      sq_bit       <= 32'd0;
      sq_rem       <= 32'd0;
    end else begin
      tgt_clr <= 1'b0;

      //--------------------------------------------------------------------
      // 旁路采样：走查期间（S_IDLE 起始拍 / S_CAPTURE 期间）每拍抓一条。
      //   id=snapshot_index；字段按协议顺序写入记录字节 0..13；
      //   d2 暂存 d2_mem，待走查结束后由 S_SQRT 补 nearest（字节 14/15）。
      //   perception_regs 的走查对 snapshot_index 0..31 每拍一条、连续 32 拍，
      //   本采样与之间读同拍，故不会错位。
      //--------------------------------------------------------------------
      if (cap_en && snapshot_busy) begin
        payload_b[4 + snapshot_index*16 + 0]  <= {3'b000, snapshot_index};
        payload_b[4 + snapshot_index*16 + 1]  <= 8'h00;              // flags=0
        payload_b[4 + snapshot_index*16 + 2]  <= w_x0[7:0];
        payload_b[4 + snapshot_index*16 + 3]  <= w_x0[15:8];
        payload_b[4 + snapshot_index*16 + 4]  <= w_x1[7:0];
        payload_b[4 + snapshot_index*16 + 5]  <= w_x1[15:8];
        payload_b[4 + snapshot_index*16 + 6]  <= w_y0[7:0];
        payload_b[4 + snapshot_index*16 + 7]  <= w_y0[15:8];
        payload_b[4 + snapshot_index*16 + 8]  <= w_y1[7:0];
        payload_b[4 + snapshot_index*16 + 9]  <= w_y1[15:8];
        payload_b[4 + snapshot_index*16 + 10] <= w_z0[7:0];
        payload_b[4 + snapshot_index*16 + 11] <= w_z0[15:8];
        payload_b[4 + snapshot_index*16 + 12] <= w_z1[7:0];
        payload_b[4 + snapshot_index*16 + 13] <= w_z1[15:8];
        // d2 为 64bit；真实值 < 2^26，超过 32bit 时饱和，使 sqrt 结果钳到 0xFFFF

      end

      case (st)
        //------------------------------------------------------------------
        S_IDLE: begin
          if (snapshot_busy) begin
            // 走查刚发起（snapshot_index=0 的当拍即被上面的采样逻辑抓走）
            cap_count <= (meta_count > TGT_MAX_C) ? TGT_MAX_C : meta_count;
            st        <= S_CAPTURE;
          end else if (have_new && send_due) begin
            // 有新表且周期到：输出 516 字节表，保持到 tgt_ack
            pub_count    <= payload_b[0];
            pub_overflow <= payload_b[1];
            tgt_valid_r  <= 1'b1;
            have_new     <= 1'b0;
            tgt_clr      <= 1'b1;
            st           <= S_PRESENT;
          end
        end

        //------------------------------------------------------------------
        S_CAPTURE: begin
          if (!snapshot_busy) begin
            // 走查结束：写 4 字节头；清零不再有用的 d2 缓冲（可选，省略）
            payload_b[0] <= {2'b00, cap_count};
            payload_b[1] <= (cap_count >= TGT_MAX_C) ? 8'd1 : 8'd0;
            payload_b[2] <= 8'h00;
            payload_b[3] <= 8'h00;
            tgt_rx_cnt   <= tgt_rx_cnt + 32'd1;
            if (cap_count == 6'd0) begin
              have_new <= 1'b1;
              st       <= S_IDLE;
            end else begin
              sq_i     <= 6'd0;
              sq_run   <= 1'b0;
              st       <= S_SQRT;
            end
          end
        end

        //------------------------------------------------------------------
        S_SQRT: begin
          if (!sq_run) begin
            // 装填一条：1 拍装填 + 16 拍迭代
            sq_rem  <= d2_mem[sq_i];
            sq_root <= 32'd0;
            sq_bit  <= 32'h4000_0000;      // 2^30 = 最高 4 的幂
            sq_step <= 5'd0;
            sq_run  <= 1'b1;
          end else begin
            sq_rem  <= sq_rem_n;
            sq_root <= sq_root_n;
            sq_bit  <= sq_bit >> 2;
            if (sq_step == 5'd15) begin
              // 第 16 步后 sq_root_n 即 floor(sqrt)
              payload_b[4 + sq_i*16 + 14] <= sq_root_n[7:0];
              payload_b[4 + sq_i*16 + 15] <= sq_root_n[15:8];
              sq_run <= 1'b0;
              if (sq_i == cap_count - 6'd1) begin
                have_new <= 1'b1;
                st       <= S_IDLE;
              end else begin
                sq_i <= sq_i + 6'd1;
              end
            end else begin
              sq_step <= sq_step + 5'd1;
            end
          end
        end

        //------------------------------------------------------------------
        S_PRESENT: begin
          if (tgt_ack) begin
            tgt_valid_r <= 1'b0;
            st          <= S_IDLE;
          end
        end

        default: st <= S_IDLE;
      endcase
    end
  end

  //==========================================================================
  // 5. 对外输出
  //==========================================================================
  assign tgt_valid    = tgt_valid_r;
  assign tgt_count    = pub_count;
  assign tgt_overflow = pub_overflow;

  generate
    for (genvar g = 0; g < TGT_BYTES; g = g + 1) begin : g_pay
      assign tgt_payload[g*8 +: 8] = payload_b[g];
    end
  endgenerate

  // 说明：snapshot_start 保留端口以匹配冻结接口，本模块用 snapshot_busy 判走查，
  //       不使用该信号（未使用属正常）。

  // RAM data writer has no asynchronous reset; control reset is unchanged.
  always_ff @(posedge clk) begin
    if (rst_n && cap_en && snapshot_busy)
      d2_mem[snapshot_index] <= (o_d2[63:32] != 32'd0) ? 32'hFFFF_FFFF : o_d2[31:0];
  end

endmodule