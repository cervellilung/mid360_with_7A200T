//============================================================================
// acx750_eth_raw_tx -- 原始以太网帧发送器（给 ARP 应答用）
//
// 行为：
//   start 单周期脉冲发起一帧；依次发
//       8 字节 前导码/SFD   = 7 x 0x55 + 1 x 0xD5
//       帧体（frame_len 字节，逐字节由 byte_idx 向调用方索取 byte_val）
//       若帧体 < 60 字节，补 0 到 60 字节（以太网最小帧要求）
//       4 字节 FCS
//   busy 期间忽略新的 start。
//
// FCS 说明（重要）：
//   复用厂商 crc32_d8.v 逐字节算 CRC32。经 Python 对拍确认：
//     crc32_d8 的 crc_result 输出 == zlib.crc32(已输入的字节)  （完全一致，
//     厂商内部做的是"输入按位反转 + 反射多项式 + 输出按位反转并取反"，
//     与标准 CRC-32/ISO-HDLC 等价）。
//   以太网 FCS 的发送顺序是 CRC 结果的小端字节序：
//     先 crc_result[7:0]，再 [15:8]，再 [23:16]，最后 [31:24]。
//   这与厂商 eth_udp_tx_gmii.v 内部的 TX_CRC 发送顺序一致。
//
// CRC 覆盖范围 = 帧体 + 补零（不含前导码）。
//============================================================================
`timescale 1ns/1ps

module acx750_eth_raw_tx (
  input  logic        clk125m,
  input  logic        rst_n,
  input  logic        start,        // 单周期脉冲：发起一帧
  input  logic [15:0] frame_len,    // 帧字节数（不含前导码与 FCS），start 当拍有效
  output logic [15:0] byte_idx,     // 当前正在取第几个字节（0 起）
  input  logic [7:0]  byte_val,     // 与 byte_idx 组合对应
  output logic        busy,         // 发送中
  output logic [7:0]  gmii_txd,
  output logic        gmii_txen
);

  // 以太网最小帧体（不含 FCS）：64 - 4(FCS) - 8(前导码/不计入长度) = 60
  localparam logic [15:0] MIN_BODY = 16'd60;

  typedef enum logic [2:0] {
    S_IDLE = 3'd0,
    S_PRE  = 3'd1,   // 前导码 + SFD
    S_BODY = 3'd2,   // 帧体
    S_PAD  = 3'd3,   // 补零到 60 字节
    S_CRC  = 3'd4    // FCS
  } state_e;

  state_e      state;
  logic [15:0] cnt;      // 当前状态内的字节计数
  logic [15:0] len_r;    // 锁存的帧体长度
  logic [15:0] pad_r;    // 需要补的字节数

  //--------------------------------------------------------------------------
  // FCS 计算：逐字节送入厂商 crc32_d8
  //   crc_init 在离开 IDLE 的那一拍拉高一拍，把内部状态复位成全 1
  //   crc_en   在发送帧体 / 补零期间保持
  //   crc_data 与当拍真正上线的字节一致（组合对齐，避免与 tx 数据错拍）
  //--------------------------------------------------------------------------
  logic        crc_init;
  logic        crc_en;
  logic [7:0]  crc_data;
  wire  [31:0] crc_result;

  assign crc_init = (state == S_IDLE) && start;
  assign crc_en   = (state == S_BODY) || (state == S_PAD);
  assign crc_data = (state == S_BODY) ? byte_val : 8'h00;

  // 用发侧那份 crc32_d8_txn（端口名 reset_n，与本模块 rst_n 同为低有效）
  crc32_d8_txn u_crc (
    .clk        (clk125m),
    .reset_n    (rst_n),
    .data       (crc_data),
    .crc_init   (crc_init),
    .crc_en     (crc_en),
    .crc_result (crc_result)
  );

  //--------------------------------------------------------------------------
  // 组合给出当拍上线的字节与 txen
  //--------------------------------------------------------------------------
  logic [7:0] tx_byte;
  logic       tx_en;

  always_comb begin
    tx_byte = 8'h00;
    tx_en   = 1'b0;
    case (state)
      S_IDLE: begin
        tx_byte = 8'h00;
        tx_en   = 1'b0;
      end
      S_PRE: begin
        tx_byte = (cnt < 16'd7) ? 8'h55 : 8'hD5;
        tx_en   = 1'b1;
      end
      S_BODY: begin
        tx_byte = byte_val;
        tx_en   = 1'b1;
      end
      S_PAD: begin
        tx_byte = 8'h00;
        tx_en   = 1'b1;
      end
      S_CRC: begin
        // FCS 小端字节序
        tx_byte = (cnt == 16'd0) ? crc_result[7:0]   :
                  (cnt == 16'd1) ? crc_result[15:8]  :
                  (cnt == 16'd2) ? crc_result[23:16] :
                                   crc_result[31:24];
        tx_en   = 1'b1;
      end
      default: begin
        tx_byte = 8'h00;
        tx_en   = 1'b0;
      end
    endcase
  end

  assign gmii_txd  = tx_byte;
  assign gmii_txen = tx_en;
  assign busy      = (state != S_IDLE);
  assign byte_idx  = (state == S_BODY) ? cnt : 16'd0;

  //--------------------------------------------------------------------------
  // 主状态机
  //--------------------------------------------------------------------------
  always_ff @(posedge clk125m or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_IDLE;
      cnt   <= 16'd0;
      len_r <= 16'd0;
      pad_r <= 16'd0;
    end else begin
      case (state)
        S_IDLE: begin
          cnt <= 16'd0;
          if (start && (frame_len != 16'd0)) begin
            len_r <= frame_len;
            pad_r <= (frame_len < MIN_BODY) ? (MIN_BODY - frame_len) : 16'd0;
            state <= S_PRE;
          end
        end

        S_PRE: begin
          if (cnt == 16'd7) begin
            cnt   <= 16'd0;
            state <= S_BODY;
          end else begin
            cnt <= cnt + 16'd1;
          end
        end

        S_BODY: begin
          if (cnt == len_r - 16'd1) begin
            cnt   <= 16'd0;
            state <= (pad_r != 16'd0) ? S_PAD : S_CRC;
          end else begin
            cnt <= cnt + 16'd1;
          end
        end

        S_PAD: begin
          if (cnt == pad_r - 16'd1) begin
            cnt   <= 16'd0;
            state <= S_CRC;
          end else begin
            cnt <= cnt + 16'd1;
          end
        end

        S_CRC: begin
          if (cnt == 16'd3) begin
            cnt   <= 16'd0;
            state <= S_IDLE;
          end else begin
            cnt <= cnt + 16'd1;
          end
        end

        default: begin
          state <= S_IDLE;
          cnt   <= 16'd0;
        end
      endcase
    end
  end

endmodule