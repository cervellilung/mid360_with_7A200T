// ============================================================================
// acx750_chassis_rx.sv
//
// 本文件从 fpga_ac880/sensor_capture_linux/rtl/imported_ps/dflink_raw_axis.v
// （AC880 顶层层级实例名 odom）改写而来，DFLink Odom v4 帧的判定逻辑等价：
//   帧头(0xDF)、逐字段约束(index 3/4/5/6/57)、16 位累加校验和的算法，均与原
//   实现逐字节一致。
// 原实现走 AXIS 握手(m_valid/m_ready/m_last)把缓冲好的整帧发往下游；这里把
//   m_ready 等价固定为 1（每拍输出一字节，第 60 字节那拍 odom_last=1），
//   即改为本接口的 odom_valid/odom_last 语义。整个模块工作在同一个 100 MHz
//   控制域，因此不再需要 XPM axis_async_fifo。
// AC880 同链路里的 dflink_subscriber 是反方向的 TX 侧周期发送器（向底盘发
//   请求帧），不参与接收判定，本文件不移植它。
// ============================================================================
`timescale 1ns/1ps

module acx750_chassis_rx #(
  parameter int unsigned CLK_HZ = 100_000_000,
  parameter int unsigned BAUD   = 460_800        // 底盘串口 460800 8N1
)(
  input  logic        clk, rst_n,       // 100 MHz 控制域
  input  logic        chassis_rxd,      // 底盘 TX -> FPGA RX（管脚待定，见文档）
  output logic [7:0]  odom_data,
  output logic        odom_valid,
  output logic        odom_last,
  // 健康计数（给 HUD/遥测看）
  output logic [31:0] rx_byte_cnt,      // 收到的字节数
  output logic [31:0] frame_ok_cnt,     // 校验通过的帧数
  output logic [31:0] frame_bad_cnt,    // 帧头/长度/CRC 错
  output logic [31:0] uart_err_cnt      // 起始位/停止位/超时等
);

  // 每比特时钟数与半比特点（与 uart_rx_8n1 一致的取整方式）
  localparam int unsigned CLKS_PER_BIT = (CLK_HZ + BAUD/2) / BAUD;
  localparam int unsigned HALF_BIT     = CLKS_PER_BIT / 2;
  // 断流超时：连续 > TIMEOUT_BITS 个比特时间收不到新字节即认为帧中断。
  // 必须大于一帧内相邻字节间隔(10 比特)，取 14 留余量。
  localparam int unsigned TIMEOUT_BITS = 14;
  localparam int unsigned TIMEOUT_CLKS = CLKS_PER_BIT * TIMEOUT_BITS;

  // -------------------------------------------------------------------------
  // UART 8N1 接收（直接在 100 MHz 域，起始位中点采样、逐位中点采样）
  // 逻辑取自 uart_rx_8n1.v，行为一致；额外把起始位误触发记为一次 uart 错误
  // -------------------------------------------------------------------------
  localparam [1:0] U_IDLE = 2'd0, U_START = 2'd1, U_DATA = 2'd2, U_STOP = 2'd3;

  logic       rx_meta, rx_sync;
  logic [1:0] ustate;
  logic [15:0] ucount;
  logic [2:0] ubit;
  logic [7:0] ushift;
  logic       uart_valid;        // 收到一个完整字节
  logic       uart_framing_err;  // 停止位非 1
  logic       uart_start_err;    // 起始位中点已回到高（毛刺/误触发）
  logic [7:0] uart_data;

  // 异步输入两级同步
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rx_meta <= 1'b1;
      rx_sync <= 1'b1;
    end else begin
      rx_meta <= chassis_rxd;
      rx_sync <= rx_meta;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ustate          <= U_IDLE;
      ucount          <= 16'd0;
      ubit            <= 3'd0;
      ushift          <= 8'h00;
      uart_valid      <= 1'b0;
      uart_framing_err<= 1'b0;
      uart_start_err  <= 1'b0;
      uart_data       <= 8'h00;
    end else begin
      uart_valid       <= 1'b0;
      uart_framing_err <= 1'b0;
      uart_start_err   <= 1'b0;
      case (ustate)
        U_IDLE: begin
          ucount <= 16'd0;
          if (!rx_sync)
            ustate <= U_START;
        end
        U_START: begin
          if (ucount == HALF_BIT-1) begin
            ucount <= 16'd0;
            if (!rx_sync) begin
              ubit   <= 3'd0;
              ustate <= U_DATA;
            end else begin
              ustate         <= U_IDLE;
              uart_start_err <= 1'b1;
            end
          end else
            ucount <= ucount + 16'd1;
        end
        U_DATA: begin
          if (ucount == CLKS_PER_BIT-1) begin
            ucount     <= 16'd0;
            ushift[ubit] <= rx_sync;
            if (ubit == 3'd7)
              ustate <= U_STOP;
            else
              ubit <= ubit + 3'd1;
          end else
            ucount <= ucount + 16'd1;
        end
        U_STOP: begin
          if (ucount == CLKS_PER_BIT-1) begin
            ucount <= 16'd0;
            if (rx_sync) begin
              uart_data  <= ushift;
              uart_valid <= 1'b1;
            end else
              uart_framing_err <= 1'b1;
            ustate <= U_IDLE;
          end else
            ucount <= ucount + 16'd1;
        end
        default: ustate <= U_IDLE;
      endcase
    end
  end

  // -------------------------------------------------------------------------
  // DFLink Odom v4 帧解析（判定逻辑移植自 dflink_raw_axis.v）
  // 帧长固定 60 字节：0xDF 帧头起，index 3/4/5/6/57 有固定值约束，
  // index 58/59 为 16 位校验和低/高字节。
  // 校验和 = bytes[0..57] 之和（低 16 位），byte0 即 0xDF。
  // -------------------------------------------------------------------------
  logic [7:0]  frame [0:59];
  logic [5:0]  write_index;
  logic [5:0]  read_index;
  logic [15:0] checksum;
  logic [7:0]  checksum_low;
  logic        collecting;
  logic        sending;
  logic [15:0] gap;             // 断流计时

  assign odom_data  = frame[read_index];
  assign odom_valid = sending;
  assign odom_last  = sending && (read_index == 6'd59);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      write_index  <= 6'd0;
      read_index   <= 6'd0;
      checksum     <= 16'h0000;
      checksum_low <= 8'h00;
      collecting   <= 1'b0;
      sending      <= 1'b0;
      gap          <= 16'd0;
      rx_byte_cnt  <= 32'd0;
      frame_ok_cnt <= 32'd0;
      frame_bad_cnt<= 32'd0;
      uart_err_cnt <= 32'd0;
    end else begin
      // 输出推进：等价于下游 m_ready 恒为 1
      if (sending) begin
        if (read_index == 6'd59) begin
          sending    <= 1'b0;
          read_index <= 6'd0;
        end else
          read_index <= read_index + 6'd1;
      end

      // UART 电平类错误（停止位/起始位误触发）
      if (uart_framing_err || uart_start_err)
        uart_err_cnt <= uart_err_cnt + 32'd1;

      if (uart_valid) begin
        rx_byte_cnt <= rx_byte_cnt + 32'd1;
        gap <= 16'd0;
        if (!collecting) begin
          if (uart_data == 8'hDF) begin
            if (sending) begin
              // 上一帧尚在输出，无法缓冲本帧：等效原 busy_drops，并入坏帧计数
              frame_bad_cnt <= frame_bad_cnt + 32'd1;
            end else begin
              frame[0]    <= uart_data;
              write_index <= 6'd1;
              checksum    <= 16'h00DF;
              collecting  <= 1'b1;
            end
          end
        end else begin
          frame[write_index] <= uart_data;
          if (write_index <= 6'd57)
            checksum <= checksum + uart_data;

          if (write_index == 6'd3 && uart_data != 8'h6C) begin
            collecting <= 1'b0; write_index <= 6'd0;
            frame_bad_cnt <= frame_bad_cnt + 32'd1;
          end else if (write_index == 6'd4 && uart_data != 8'h80) begin
            collecting <= 1'b0; write_index <= 6'd0;
            frame_bad_cnt <= frame_bad_cnt + 32'd1;
          end else if (write_index == 6'd5 && uart_data != 8'd51) begin
            collecting <= 1'b0; write_index <= 6'd0;
            frame_bad_cnt <= frame_bad_cnt + 32'd1;
          end else if (write_index == 6'd6 && uart_data != 8'h04) begin
            collecting <= 1'b0; write_index <= 6'd0;
            frame_bad_cnt <= frame_bad_cnt + 32'd1;
          end else if (write_index == 6'd57 && uart_data != 8'hFD) begin
            collecting <= 1'b0; write_index <= 6'd0;
            frame_bad_cnt <= frame_bad_cnt + 32'd1;
          end else if (write_index == 6'd58) begin
            checksum_low <= uart_data;
            write_index  <= 6'd59;
          end else if (write_index == 6'd59) begin
            collecting  <= 1'b0;
            write_index <= 6'd0;
            if ({uart_data, checksum_low} == checksum) begin
              sending      <= 1'b1;
              read_index   <= 6'd0;
              frame_ok_cnt <= frame_ok_cnt + 32'd1;
            end else
              frame_bad_cnt <= frame_bad_cnt + 32'd1;
          end else
            write_index <= write_index + 6'd1;
        end
      end else if (collecting) begin
        // 断流：长时间无新字节 -> 回到帧头搜索态，计入 uart 错误
        if (gap == TIMEOUT_CLKS-1) begin
          collecting   <= 1'b0;
          write_index  <= 6'd0;
          gap          <= 16'd0;
          uart_err_cnt <= uart_err_cnt + 32'd1;
        end else
          gap <= gap + 16'd1;
      end
    end
  end

endmodule