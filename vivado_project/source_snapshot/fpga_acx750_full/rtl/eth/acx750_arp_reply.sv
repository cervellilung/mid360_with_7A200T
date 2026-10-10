//============================================================================
// acx750_arp_reply -- ARP 请求解析与应答帧内容生成
//
// 功能：
//   1) 只对 Ethernet type = 0x0806、ARP opcode = 1(request)、target IP == `PL_IP
//      的帧回应一个标准 ARP reply（sender = PL_MAC/PL_IP，target = 请求方）。
//   2) 学习对端 MAC/IP（peer_mac / peer_ip）：
//        - 收到 ARP(0x0806) 或 IPv4(0x0800) 帧时，把源 MAC 记为 peer_mac
//        - IPv4 帧把源 IP 记为 peer_ip；ARP 请求把请求方 IP 记为 peer_ip
//      复位默认 peer_mac = 广播 FF:FF:FF:FF:FF:FF，peer_ip = 0。
//   3) 对畸形帧做长度/超时保护，绝不会卡死（bcnt 封顶 + 前导码计数封顶）。
//
// 应答帧内容以"组合函数 + reply_idx"的方式给出，帧体共 42 字节
// （不足 60 字节由 acx750_eth_raw_tx 自动补零再算 FCS）。
// 为了配合可能被仲裁器推迟的发送，请求方的 MAC/IP 在识别当拍就锁存进寄存器，
// 保证后续任意时刻 reply_val 都是稳定的。
//
// 注意：ARP 请求帧一旦被识别就立刻排队应答；若同一时刻另一路（UDP）正在占用
// PHY，仲裁器会自动延后。此模块不接收"发送忙"反馈，因此若在极短窗口内连续
// 收到两个 ARP 请求，第二个会覆盖第一个的应答内容（见文件末 TODO）。
//============================================================================
`timescale 1ns/1ps

`include "../acx750_defs.svh"

module acx750_arp_reply (
  input  logic        clk125m,       // 与 gmii_rx_clk 同域
  input  logic        rst_n,
  input  logic [7:0]  gmii_rxd,
  input  logic        gmii_rxdv,
  // 应答帧内容（组合给出，供 acx750_eth_raw_tx 用）
  output logic        reply_start,   // 单周期脉冲
  output logic [15:0] reply_len,
  input  logic [15:0] reply_idx,
  output logic [7:0]  reply_val,
  // 统计
  output logic [31:0] arp_req_cnt,
  output logic [31:0] arp_rsp_cnt,
  // 学到对端（点云发送方）的 MAC/IP
  output logic [47:0] peer_mac,
  output logic [31:0] peer_ip
);

  localparam logic [47:0] PL_MAC_C = `PL_MAC;
  localparam logic [31:0] PL_IP_C  = `PL_IP;

  // 应答帧体长度（ARP 标准为 42 字节，余下由 raw_tx 补零）
  localparam logic [15:0] RSP_LEN  = 16'd42;

  // 单帧最多解析的字节数（超长直接丢弃，防卡死）
  localparam logic [11:0] MAX_BCNT = 12'd2047;

  //--------------------------------------------------------------------------
  // 输入打一拍
  //--------------------------------------------------------------------------
  logic [7:0] rxd_s;
  logic       dv_s;
  logic       dv_s_d;

  always_ff @(posedge clk125m or negedge rst_n) begin
    if (!rst_n) begin
      rxd_s  <= 8'h00;
      dv_s   <= 1'b0;
      dv_s_d <= 1'b0;
    end else begin
      rxd_s  <= gmii_rxd;
      dv_s   <= gmii_rxdv;
      dv_s_d <= dv_s;
    end
  end

  //--------------------------------------------------------------------------
  // 解析寄存器与状态
  //--------------------------------------------------------------------------
  typedef enum logic [1:0] {
    P_IDLE  = 2'd0,
    P_PRE   = 2'd1,   // 前导码（等 0xD5 SFD）
    P_FRAME = 2'd2    // 帧体
  } pstate_e;

  pstate_e     ps;
  logic [5:0]  pcnt;      // 前导码 0x55 计数
  logic [11:0] bcnt;      // 帧内字节序号（SFD 之后为 0）
  logic        checked;   // 本帧是否已做过一次判定

  logic [47:0] src_mac;
  logic [15:0] eth_type;
  logic [15:0] arp_op;
  logic [47:0] arp_sha;
  logic [31:0] arp_spa;
  logic [31:0] arp_tpa;
  logic [31:0] ip_src;

  logic        hit;       // 本帧为发给本机的 ARP 请求
  logic [47:0] req_mac;   // 请求方 MAC（应答目的 MAC / target 硬件地址）
  logic [31:0] req_ip;    // 请求方 IP （target 协议地址）

  assign reply_len = RSP_LEN;

  //--------------------------------------------------------------------------
  // 解析状态机（同时完成对端学习、请求计数、应答触发）
  //--------------------------------------------------------------------------
  always_ff @(posedge clk125m or negedge rst_n) begin
    if (!rst_n) begin
      ps          <= P_IDLE;
      pcnt        <= 6'd0;
      bcnt        <= 12'd0;
      checked     <= 1'b0;
      src_mac     <= 48'd0;
      eth_type    <= 16'd0;
      arp_op      <= 16'd0;
      arp_sha     <= 48'd0;
      arp_spa     <= 32'd0;
      arp_tpa     <= 32'd0;
      ip_src      <= 32'd0;
      hit         <= 1'b0;
      req_mac     <= 48'd0;
      req_ip      <= 32'd0;
      reply_start <= 1'b0;
      arp_req_cnt <= 32'd0;
      arp_rsp_cnt <= 32'd0;
      peer_mac    <= 48'hFF_FF_FF_FF_FF_FF;
      peer_ip     <= 32'h0000_0000;
    end else begin
      reply_start <= 1'b0;              // 默认不脉冲

      case (ps)
        //------------------------------------------------------------------
        P_IDLE: begin
          checked <= 1'b0;
          hit     <= 1'b0;
          if (dv_s && !dv_s_d) begin        // 帧开始（rxdv 上升沿）
            pcnt     <= 6'd0;
            bcnt     <= 12'd0;
            src_mac  <= 48'd0;
            eth_type <= 16'd0;
            arp_op   <= 16'd0;
            arp_sha  <= 48'd0;
            arp_spa  <= 32'd0;
            arp_tpa  <= 32'd0;
            ip_src   <= 32'd0;
            ps       <= P_PRE;
          end
        end

        //------------------------------------------------------------------
        P_PRE: begin
          if (!dv_s) begin                  // 前导码没等到 SFD 就结束
            ps <= P_IDLE;
          end else if (rxd_s == 8'hD5) begin // 找到 SFD，下一拍即帧体第 0 字节
            bcnt <= 12'd0;
            ps   <= P_FRAME;
          end else if (pcnt > 6'd15) begin   // 前导码异常长：放弃
            ps <= P_IDLE;
          end else begin
            pcnt <= pcnt + 6'd1;
          end
        end

        //------------------------------------------------------------------
        P_FRAME: begin
          if (!dv_s) begin
            // ---- 帧结束：学习对端，必要时触发应答 ----
            if ((bcnt >= 12'd14) &&
                ((eth_type == 16'h0806) || (eth_type == 16'h0800))) begin
              peer_mac <= src_mac;
              if ((eth_type == 16'h0800) && (bcnt >= 12'd30))
                peer_ip <= ip_src;
              else if (hit)
                peer_ip <= req_ip;
            end
            if (hit) begin
              reply_start <= 1'b1;
              arp_rsp_cnt <= arp_rsp_cnt + 32'd1;
            end
            ps <= P_IDLE;
          end else begin
            // ---- 逐字节解析（用当拍 bcnt 作为字节下标）----
            if ((bcnt >= 12'd6) && (bcnt <= 12'd11))
              src_mac <= {src_mac[39:0], rxd_s};
            if (bcnt == 12'd12)
              eth_type[15:8] <= rxd_s;
            if (bcnt == 12'd13)
              eth_type[7:0] <= rxd_s;
            if ((bcnt >= 12'd20) && (bcnt <= 12'd21))
              arp_op <= {arp_op[7:0], rxd_s};
            if ((bcnt >= 12'd22) && (bcnt <= 12'd27))
              arp_sha <= {arp_sha[39:0], rxd_s};
            if ((bcnt >= 12'd28) && (bcnt <= 12'd31))
              arp_spa <= {arp_spa[23:0], rxd_s};
            if ((bcnt >= 12'd38) && (bcnt <= 12'd41))
              arp_tpa <= {arp_tpa[23:0], rxd_s};
            // IPv4 源 IP（帧偏移 26..29），用于学习点云发送方
            if ((eth_type == 16'h0800) && (bcnt >= 12'd26) && (bcnt <= 12'd29))
              ip_src <= {ip_src[23:0], rxd_s};

            // ---- 收齐 42 字节后做一次判定 ----
            if (!checked && (bcnt == 12'd42)) begin
              checked <= 1'b1;
              if ((eth_type == 16'h0806) && (arp_op == 16'd1) &&
                  (arp_tpa == PL_IP_C) && (arp_sha != 48'd0)) begin
                hit         <= 1'b1;
                req_mac     <= arp_sha;
                req_ip      <= arp_spa;
                arp_req_cnt <= arp_req_cnt + 32'd1;
              end
            end

            // ---- 长度保护 ----
            if (bcnt >= MAX_BCNT)
              ps <= P_IDLE;
            else
              bcnt <= bcnt + 12'd1;
          end
        end

        default: ps <= P_IDLE;
      endcase
    end
  end

  //--------------------------------------------------------------------------
  // 应答帧内容（组合）
  //--------------------------------------------------------------------------
  always_comb begin
    reply_val = 8'h00;
    case (reply_idx)
      // 目的 MAC = 请求方 MAC
      16'd0:  reply_val = req_mac[47:40];
      16'd1:  reply_val = req_mac[39:32];
      16'd2:  reply_val = req_mac[31:24];
      16'd3:  reply_val = req_mac[23:16];
      16'd4:  reply_val = req_mac[15:8];
      16'd5:  reply_val = req_mac[7:0];
      // 源 MAC = PL_MAC
      16'd6:  reply_val = PL_MAC_C[47:40];
      16'd7:  reply_val = PL_MAC_C[39:32];
      16'd8:  reply_val = PL_MAC_C[31:24];
      16'd9:  reply_val = PL_MAC_C[23:16];
      16'd10: reply_val = PL_MAC_C[15:8];
      16'd11: reply_val = PL_MAC_C[7:0];
      // EtherType = 0x0806 (ARP)
      16'd12: reply_val = 8'h08;
      16'd13: reply_val = 8'h06;
      // 硬件类型 = 0x0001 (Ethernet)
      16'd14: reply_val = 8'h00;
      16'd15: reply_val = 8'h01;
      // 协议类型 = 0x0800 (IPv4)
      16'd16: reply_val = 8'h08;
      16'd17: reply_val = 8'h00;
      // 硬件长度 6 / 协议长度 4
      16'd18: reply_val = 8'h06;
      16'd19: reply_val = 8'h04;
      // opcode = 2 (reply)
      16'd20: reply_val = 8'h00;
      16'd21: reply_val = 8'h02;
      // sender 硬件地址 = PL_MAC
      16'd22: reply_val = PL_MAC_C[47:40];
      16'd23: reply_val = PL_MAC_C[39:32];
      16'd24: reply_val = PL_MAC_C[31:24];
      16'd25: reply_val = PL_MAC_C[23:16];
      16'd26: reply_val = PL_MAC_C[15:8];
      16'd27: reply_val = PL_MAC_C[7:0];
      // sender 协议地址 = PL_IP
      16'd28: reply_val = PL_IP_C[31:24];
      16'd29: reply_val = PL_IP_C[23:16];
      16'd30: reply_val = PL_IP_C[15:8];
      16'd31: reply_val = PL_IP_C[7:0];
      // target 硬件地址 = 请求方 MAC
      16'd32: reply_val = req_mac[47:40];
      16'd33: reply_val = req_mac[39:32];
      16'd34: reply_val = req_mac[31:24];
      16'd35: reply_val = req_mac[23:16];
      16'd36: reply_val = req_mac[15:8];
      16'd37: reply_val = req_mac[7:0];
      // target 协议地址 = 请求方 IP
      16'd38: reply_val = req_ip[31:24];
      16'd39: reply_val = req_ip[23:16];
      16'd40: reply_val = req_ip[15:8];
      16'd41: reply_val = req_ip[7:0];
      default: reply_val = 8'h00;
    endcase
  end

  // TODO: 若后续要避免"连续两个 ARP 请求互相覆盖应答内容"，需要给本模块增加
  //       一个来自仲裁器的 "reply_busy" 输入，在此把应答内容锁存到双缓冲里。

endmodule