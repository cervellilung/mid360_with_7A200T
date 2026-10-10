//============================================================================
// acx750_grid_reader -- 把 lidar_grid 的内部栅格转置成 M3TL type=5 位图
//
// 背景（见 docs/recon_880_perception.md §2.7 / §3-GAP-E / §5-R1）：
//   * lidar_grid 内部是 60 行(y/纵深) x 55 列(x/横向)，线性下标
//       idx = y_idx*55 + x_idx   （y_idx∈[0,60), x_idx∈[0,55)）。
//   * M3TL type=5 约定是 55 行 x 60 列、行优先、每字节 bit0 起：
//       格子 (r,c) -> 线性 n = r*60 + c -> byte n>>3 的 bit(n&7)。
//   两者是转置关系：外部 (r,c) 对应内部 (x=r, y=c)，即
//       n = r*60 + c   <=>   idx = c*55 + r
//   依据：acx750_defs.svh:51-55（GRID_ROWS=55/GRID_COLS=60/GRID_BYTES=413）、
//   acx750_m3tl_tx.sv:440-444（n=row*60+col，bit(n&7)）、host/m3tl.py
//   grid_index/pack_bitmap（row*cols+col、byte[i>>3] 的 bit(i&7)），以及
//   recon 报告对内部地址 idx=y*55+x 的逐行核对。方向搞反会导致上位机画的栅格
//   整体“横躺”，故本模块显式做 idx = c*55 + r 的转置。
//
// 【与 M3TL 发送器的握手契约】（rtl/eth/acx750_m3tl_full_tx.sv 的 tb 桩口径）：
//   start（单周期脉冲）
//     -> 读出器锁存 55x60 栅格（内部约 3300*3 拍）
//     -> done（单周期脉冲，"数据已稳定可读"）
//     -> 紧接着连续 413 拍 byte_valid=1、byte_out=该字节、byte_index=0..412
//     -> 之后 byte_valid=0，回到空闲
//   注意 done 必须在 413 字节之前。
//
// 位宽：地址位宽 AW = $clog2(ROWS*COLS) = $clog2(3300) = 12，即 [11:0]，
//       与 rtl/video/acx750_ar_wrap.sv / perception_engine 的口径一致。
//============================================================================
`timescale 1ns/1ps
module acx750_grid_reader #(
  parameter integer ROWS = 55,   // 外部（M3TL）行数 = 内部 x 数 = 55
  parameter integer COLS = 60    // 外部（M3TL）列数 = 内部 y 数 = 60
)(
  input  logic          clk,
  input  logic          rst_n,       // 低有效
  input  logic          start,       // 单周期脉冲：开始一次快照
  output logic          busy,
  output logic          done,        // 单周期脉冲：快照完成（在字节流之前）
  output logic [15:0]   rd_addr,     // 当前驱动的内部线性地址（测试/调试）
  output logic [7:0]    byte_out,    // M3TL type=5 位图第 N 字节
  output logic          byte_valid,
  output logic [15:0]   byte_index,
  // 接 perception_engine 的栅格只读透传口
  output logic [11:0]   grid_rd_addr,
  input  logic [7:0]    grid_rd_data
);

  localparam integer CELLS  = ROWS*COLS;     // 3300
  localparam integer NBYTES = (CELLS+7)/8;   // 413
  localparam integer AW     = $clog2(CELLS); // 12
  localparam integer IR     = COLS;          // 内部行数(y) = 60
  localparam integer IC     = ROWS;          // 内部列数(x) = 55
  localparam integer STRIDE = IC;            // 内部行跨距 = 55

  // 413 字节快照缓冲（413x8 ≈ 3.3kbit 寄存器）
  logic [7:0] sbyte [0:NBYTES-1];

  typedef enum logic [2:0] {S_IDLE,S_ADDR,S_SAMPLE,S_EMIT,S_DONE,S_STREAM} state_e;
  state_e st;

  logic [5:0]  rr, cc;        // 外部行 r(0..54)/列 c(0..59)
  logic [11:0] idx;           // 内部线性地址 = c*55 + r
  logic [2:0]  bitpos;
  logic [15:0] bidx;
  logic [7:0]  bacc;
  logic        occ;

  wire [7:0]  nbyte     = bacc | (occ ? (8'd1 << bitpos) : 8'd0);
  wire        last_cell = (rr == ROWS-1) && (cc == COLS-1);
  wire        emit_byte = (bitpos == 3'd7) || last_cell;

  assign busy         = (st != S_IDLE);
  assign done         = (st == S_DONE);
  assign byte_valid   = (st == S_STREAM);
  assign byte_out     = sbyte[bidx];
  assign byte_index   = bidx;
  assign grid_rd_addr = idx[11:0];
  assign rd_addr      = {4'd0, idx[11:0]};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st     <= S_IDLE;
      rr     <= '0;
      cc     <= '0;
      idx    <= '0;
      bitpos <= '0;
      bidx   <= '0;
      bacc   <= '0;
      occ    <= 1'b0;
    end else begin
      case (st)
        S_IDLE: begin
          if (start) begin
            rr <= '0; cc <= '0; idx <= '0; bitpos <= '0; bidx <= '0; bacc <= '0;
            st <= S_ADDR;
          end
        end
        // 把当前 idx 送进 lidar_grid 的 B 读口（combinational）
        S_ADDR: st <= S_SAMPLE;
        // B 口是寄存读出，滞后一拍；此拍 grid_rd_data 即 mem[idx]
        S_SAMPLE: begin
          occ <= (grid_rd_data != 8'd0);
          st  <= S_EMIT;
        end
        // 打包当前位并推进
        S_EMIT: begin
          if (emit_byte) begin

            bacc      <= 8'd0;
            bitpos    <= 3'd0;
            if (last_cell) begin
              st <= S_DONE;
            end else begin
              bidx <= bidx + 1'b1;
              if (cc == COLS-1) begin cc <= '0; rr <= rr + 1'b1; idx <= rr + 1'b1; end
              else              begin cc <= cc + 1'b1; idx <= idx + STRIDE; end
              st <= S_ADDR;
            end
          end else begin
            bacc   <= nbyte;
            bitpos <= bitpos + 1'b1;
            if (cc == COLS-1) begin cc <= '0; rr <= rr + 1'b1; idx <= rr + 1'b1; end
            else              begin cc <= cc + 1'b1; idx <= idx + STRIDE; end
            st <= S_ADDR;
          end
        end
        // done 单周期脉冲：413 字节已写入 sbyte，可紧接读出
        S_DONE: begin
          bidx <= '0;
          st   <= S_STREAM;
        end
        // 连续 413 拍输出
        S_STREAM: begin
          if (bidx == NBYTES-1) st <= S_IDLE;
          else                  bidx <= bidx + 1'b1;
        end
        default: st <= S_IDLE;
      endcase
    end
  end

  // RAM data writer has no asynchronous reset; control reset is unchanged.
  always_ff @(posedge clk) begin
    if (rst_n && st == S_EMIT && emit_byte)
      sbyte[bidx] <= nbyte;
  end

endmodule