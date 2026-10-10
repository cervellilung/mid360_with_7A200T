//============================================================================
// acx750_cfg_bridge -- 树莓派 UDP 下行配置 → AXI-Lite 主机 → perception_regs
//
// 协议与寄存器映射权威定义：docs/control_plane_750.md
//
// 背景：
//   7020 上 perception_regs（4 KiB AXI-Lite 从口，纯 RTL，无 Xilinx IP）由
//   PS7 通过 M_AXI_GP1 读写。750 无 PS，改为树莓派经 UDP 下行配置。本模块把
//   「下行字节流」翻译成「AXI-Lite 主机时序」，寄存器映射与上电默认值全部
//   原样保留（perception_regs 一行未改）。
//
// 本模块只做 100 MHz 控制域逻辑（= clk_sys）。125→100 MHz 的字节流 CDC 由
// acx750_radar_stream（异步 FIFO）负责，不在本模块内。
//
// 下行包（UDP 载荷，全部小端）：
//   偏移 0        opcode  u8    0x01 写单字 / 0x02 读单字 / 0x03 批量写 / 0x04 触发快照读
//   偏移 1        count   u8    仅 0x03 有意义（1..16），其余填 1
//   偏移 2/3      reserved u8   0
//   偏移 4..      重复 count 组，每组：word_index:u16，然后（仅写）value:u32
//
//   注意：word_index 是 **32-bit 字地址 0x000..0x3FF**，
//         AXI 字节地址 = word_index * 4。
//
// 设计要点：
//   1. 先把整包收进 128 字节小缓冲（含末字节标志 cfg_last），再解析；不在流中间
//      直接发 AXI，避免半包/错位。
//   2. AXI-Lite 写通道：AW/W 独立握手（可同拍给出），各自 ready 后等 B 响应；
//      读通道：AR 握手后等 R（rready 常 1）。
//   3. 批量写按顺序逐字完成，count 个字全部成功才算一包成功；中途 bresp!=0 立即
//      判坏并回空闲。
//   4. 任何异常（缓冲溢出 / 长度不符 / opcode 未知 / AXI 响应非 OKAY）→
//      cfg_bad_cnt++，状态机必回空闲，绝不卡死。
//   5. 可综合：无 initial / #delay / real / XPM / IP。
//============================================================================
`timescale 1ns/1ps

module acx750_cfg_bridge (
  input  logic         clk, rst_n,        // 100 MHz 控制域（= clk_sys）
  // 配置字节流（已由异步 FIFO 搬到本域）
  input  logic [7:0]   cfg_data,
  input  logic         cfg_valid,
  input  logic         cfg_last,          // 本包最后一个字节
  // AXI-Lite 主机 → perception_regs（位宽按 perception_regs 的从口，地址 12 位）
  output logic [11:0]  m_axi_awaddr,
  output logic [2:0]   m_axi_awprot,
  output logic         m_axi_awvalid,
  input  logic         m_axi_awready,
  output logic [31:0]  m_axi_wdata,
  output logic [3:0]   m_axi_wstrb,
  output logic         m_axi_wvalid,
  input  logic         m_axi_wready,
  input  logic [1:0]   m_axi_bresp,
  input  logic         m_axi_bvalid,
  output logic         m_axi_bready,
  output logic [11:0]  m_axi_araddr,
  output logic [2:0]   m_axi_arprot,
  output logic         m_axi_arvalid,
  input  logic         m_axi_arready,
  input  logic [31:0]  m_axi_rdata,
  input  logic [1:0]   m_axi_rresp,
  input  logic         m_axi_rvalid,
  output logic         m_axi_rready,
  // 读回（给上层做 M3TL type=7）
  output logic [31:0]  rb_word_index,
  output logic [31:0]  rb_value,
  output logic         rb_valid,
  // 统计
  output logic [31:0]  cfg_pkt_cnt,
  output logic [31:0]  cfg_bad_cnt
);

  //--------------------------------------------------------------------------
  // 协议常量
  //--------------------------------------------------------------------------
  localparam logic [7:0] OP_WR_SINGLE = 8'h01;
  localparam logic [7:0] OP_RD_SINGLE = 8'h02;
  localparam logic [7:0] OP_WR_BATCH  = 8'h03;
  localparam logic [7:0] OP_SNAP_RD   = 8'h04;

  localparam int         BUF_BYTES    = 128;             // 下行载荷总长上限
  localparam logic [9:0] SNAP_NGRP    = 10'd416;         // 快照窗口 0x800..0xE7F = 416 字
  localparam logic [15:0]SNAP_WID_BASE= 16'h0200;        // 0x800 字节 ÷ 4

  assign m_axi_awprot = 3'b000;
  assign m_axi_arprot = 3'b000;

  //--------------------------------------------------------------------------
  // 1. 接收缓冲与状态
  //--------------------------------------------------------------------------
  logic [7:0] pkt_buf [0:BUF_BYTES-1];   // 整包字节（先收后解析）
  logic [7:0] wr_ptr;                // 已收字节数（0..128）
  logic       overflow;              // 本包超过 128 字节

  typedef enum logic [2:0] {
    S_IDLE,     // 等首字节
    S_COLLECT,  // 收后续字节
    S_PARSE,    // 校验 + 分派
    S_WR_AS,    // 写：AW/W 握手
    S_WR_B,     // 写：等 B 响应
    S_RD_AS,    // 读：AR 握手
    S_RD_R      // 读：等 R 数据
  } state_e;

  state_e      st;
  logic [9:0]  ngrp;       // 本包组数
  logic [9:0]  grp_idx;    // 当前组序号
  logic        wr_op;      // 1=写（带 value），0=读
  logic [2:0]  stride;     // 每组字节数（写 6 / 读 2）
  logic        snap_mode;  // opcode=0x04 的整块快照读
  logic        aw_done, w_done;  // AW/W 独立握手完成标志

  //--------------------------------------------------------------------------
  // 2. 解析（组合）：从缓冲首字节/长度判定本包是否合法
  //--------------------------------------------------------------------------
  logic        parse_ok;
  logic [7:0]  p_opcode;
  logic [9:0]  p_ngrp;
  logic        p_wr_op;
  logic [2:0]  p_stride;
  logic        p_snap;

  always_comb begin
    parse_ok = 1'b0;
    p_opcode = pkt_buf[0];
    p_ngrp   = 10'd1;
    p_wr_op  = 1'b0;
    p_stride = 3'd2;
    p_snap   = 1'b0;
    if (!overflow) begin
      case (pkt_buf[0])
        // 写单字：4 头 + 2 索引 + 4 值 = 10 字节
        OP_WR_SINGLE: begin
          if (wr_ptr == 8'd10) begin
            parse_ok = 1'b1; p_ngrp = 10'd1; p_wr_op = 1'b1; p_stride = 3'd6;
          end
        end
        // 读单字：4 头 + 2 索引 = 6 字节
        OP_RD_SINGLE: begin
          if (wr_ptr == 8'd6) begin
            parse_ok = 1'b1; p_ngrp = 10'd1; p_wr_op = 1'b0; p_stride = 3'd2;
          end
        end
        // 批量写：4 头 + count*(2 索引 + 4 值)，count 1..16
        OP_WR_BATCH: begin
          if ((pkt_buf[1] >= 8'd1) && (pkt_buf[1] <= 8'd16)) begin
            if (wr_ptr == (8'd4 + pkt_buf[1] * 8'd6)) begin
              parse_ok = 1'b1; p_ngrp = {2'b0, pkt_buf[1]};
              p_wr_op = 1'b1; p_stride = 3'd6;
            end
          end
        end
        // 触发快照读：只有 4 字节头，回读整块 416 字
        OP_SNAP_RD: begin
          if (wr_ptr == 8'd4) begin
            parse_ok = 1'b1; p_ngrp = SNAP_NGRP; p_wr_op = 1'b0;
            p_stride = 3'd2; p_snap = 1'b1;
          end
        end
        default: parse_ok = 1'b0;   // 未知 opcode
      endcase
    end
  end

  //--------------------------------------------------------------------------
  // 3. 当前组字段抽取
  //    grp_off 仅非快照时用于索引 buf；快照读的 word_index 由基址 + grp_idx 生成。
  //    非快照 grp_idx<=15、stride<=6 → grp_off<=94，不会越界。
  //--------------------------------------------------------------------------
  logic [6:0]  grp_off;
  logic [15:0] cur_widx;
  logic [31:0] cur_value;
  logic [11:0] cur_addr;

  assign grp_off = 7'(8'd4 + (grp_idx[3:0] * stride));

  always_comb begin
    if (snap_mode)
      cur_widx = SNAP_WID_BASE + {6'b0, grp_idx};      // grp_idx 0..415
    else
      cur_widx = { pkt_buf[grp_off + 7'd1], pkt_buf[grp_off] };
  end

  always_comb begin
    if (wr_op)   // 组内布局：[word_index:u16][value:u32]，value 从组内偏移 2 起
      cur_value = { pkt_buf[grp_off + 7'd5], pkt_buf[grp_off + 7'd4],
                    pkt_buf[grp_off + 7'd3], pkt_buf[grp_off + 7'd2] };
    else
      cur_value = 32'h0;
  end

  // AXI 字节地址 = word_index * 4（word_index 有效范围 0x000..0x3FF）
  assign cur_addr = { cur_widx[9:0], 2'b00 };

  //--------------------------------------------------------------------------
  // 4. AXI-Lite 输出（按状态驱动，避免多驱动/隐式锁存）
  //--------------------------------------------------------------------------
  always_comb begin
    m_axi_awvalid = 1'b0;
    m_axi_awaddr  = 12'h000;
    m_axi_wvalid  = 1'b0;
    m_axi_wdata   = 32'h0;
    m_axi_wstrb   = 4'h0;
    m_axi_bready  = 1'b0;
    m_axi_arvalid = 1'b0;
    m_axi_araddr  = 12'h000;
    m_axi_rready  = 1'b1;   // R 通道始终就绪
    case (st)
      S_WR_AS: begin
        m_axi_awvalid = ~aw_done;      // AW/W 可同拍给出，各自 ready 后撤销
        m_axi_awaddr  = cur_addr;
        m_axi_wvalid  = ~w_done;
        m_axi_wdata   = cur_value;
        m_axi_wstrb   = 4'hF;
      end
      S_WR_B: begin
        m_axi_bready = 1'b1;
      end
      S_RD_AS: begin
        m_axi_arvalid = 1'b1;
        m_axi_araddr  = cur_addr;
      end
      default: ;
    endcase
  end

  //--------------------------------------------------------------------------
  // 5. 主状态机
  //--------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st            <= S_IDLE;
      wr_ptr        <= 8'd0;
      overflow      <= 1'b0;
      ngrp          <= 10'd1;
      grp_idx       <= 10'd0;
      wr_op         <= 1'b0;
      stride        <= 3'd2;
      snap_mode     <= 1'b0;
      aw_done       <= 1'b0;
      w_done        <= 1'b0;
      rb_valid      <= 1'b0;
      rb_word_index <= 32'h0;
      rb_value      <= 32'h0;
      cfg_pkt_cnt   <= 32'h0;
      cfg_bad_cnt   <= 32'h0;
    end else begin
      rb_valid <= 1'b0;   // 默认单拍脉冲

      case (st)
        //--- 空闲：等首字节 ---
        S_IDLE: begin
          wr_ptr   <= 8'd0;
          overflow <= 1'b0;
          if (cfg_valid) begin
            pkt_buf[0] <= cfg_data;
            wr_ptr <= 8'd1;
            if (cfg_last) st <= S_PARSE;
            else          st <= S_COLLECT;
          end
        end

        //--- 收后续字节，直到 cfg_last ---
        S_COLLECT: begin
          if (cfg_valid) begin
            if (wr_ptr < BUF_BYTES) begin
              pkt_buf[wr_ptr] <= cfg_data;
              wr_ptr      <= wr_ptr + 8'd1;
            end else begin
              overflow <= 1'b1;          // 超长：继续丢字节直到 cfg_last
            end
            if (cfg_last) st <= S_PARSE;
          end
        end

        //--- 校验并分派 ---
        S_PARSE: begin
          if (!parse_ok) begin
            cfg_bad_cnt <= cfg_bad_cnt + 32'd1;
            st          <= S_IDLE;
          end else begin
            ngrp      <= p_ngrp;
            wr_op     <= p_wr_op;
            stride    <= p_stride;
            snap_mode <= p_snap;
            grp_idx   <= 10'd0;
            aw_done   <= 1'b0;
            w_done    <= 1'b0;
            st        <= p_wr_op ? S_WR_AS : S_RD_AS;
          end
        end

        //--- 写：AW/W 握手 ---
        S_WR_AS: begin
          if (m_axi_awvalid && m_axi_awready) aw_done <= 1'b1;
          if (m_axi_wvalid  && m_axi_wready ) w_done  <= 1'b1;
          if ((aw_done || (m_axi_awvalid && m_axi_awready)) &&
              (w_done  || (m_axi_wvalid  && m_axi_wready )))
            st <= S_WR_B;
        end

        //--- 写：等 B 响应 ---
        S_WR_B: begin
          if (m_axi_bvalid) begin
            if (m_axi_bresp != 2'b00) begin
              cfg_bad_cnt <= cfg_bad_cnt + 32'd1;   // AXI 错误 → 整包判坏
              st          <= S_IDLE;
            end else if (grp_idx == ngrp - 10'd1) begin
              cfg_pkt_cnt <= cfg_pkt_cnt + 32'd1;   // 最后一个字也成功，包成功
              st          <= S_IDLE;
            end else begin
              grp_idx <= grp_idx + 10'd1;
              aw_done <= 1'b0;
              w_done  <= 1'b0;
              st      <= S_WR_AS;
            end
          end
        end

        //--- 读：AR 握手 ---
        S_RD_AS: begin
          if (m_axi_arvalid && m_axi_arready) st <= S_RD_R;
        end

        //--- 读：等 R 数据，出 rb 脉冲 ---
        S_RD_R: begin
          if (m_axi_rvalid) begin
            if (m_axi_rresp != 2'b00) begin
              cfg_bad_cnt <= cfg_bad_cnt + 32'd1;
              st          <= S_IDLE;
            end else begin
              rb_valid      <= 1'b1;
              rb_value      <= m_axi_rdata;
              rb_word_index <= {16'b0, cur_widx};
              if (grp_idx == ngrp - 10'd1) begin
                cfg_pkt_cnt <= cfg_pkt_cnt + 32'd1;
                st          <= S_IDLE;
              end else begin
                grp_idx <= grp_idx + 10'd1;
                st      <= S_RD_AS;
              end
            end
          end
        end

        default: st <= S_IDLE;
      endcase
    end
  end

endmodule