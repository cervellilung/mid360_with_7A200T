//============================================================================
// acx750_udp_rx -- 不带内部 BUFG 的以太网 UDP 接收器（GMII 侧）
//
// 背景（见 docs/known_gaps.md G8）：
//   厂商 eth_udp_rx_gmii 内部自带 `BUFG BUFG_pclk(.I(gmii_rx_clk), ...)`。
//   同一个 MMCM 输出脚上只能挂一份 BUFG，所以厂商版在"一路 RX 时钟 + 多 UDP
//   服务端口"的用法下无法例化两份。本模块把 BUFG 剥离出去，把 GMII 接收时钟
//   作为普通输入 clk 接收，顶层只用 **一个** BUFG，即可在同一时钟域上例化任意
//   多份（每端口一份）。
//
// 行为基准（重要）：
//   本模块是 rtl/vendor_ref/eth_rx/eth_udp_rx_gmii.v 的**行为等价移植**：
//   内部流水级数、状态机、计数与判定条件逐条对齐，只做了三处结构性改动：
//     1) 去掉内部 BUFG，clk125m 改为端口输入 `clk`；
//     2) 去掉 clk125m_o 输出（时钟由顶层 BUFG 提供）；
//     3) 去掉仅供调试的 debug_crc_check 输出（对拍 tb 不需要它）。
//   对拍结果见 sim/tb_udp_rx_ab.sv。凡与厂商不同的地方都已在 docs/udp_rx_750.md
//   中逐条标注；本文件的判定条件与厂商**完全一致**，未做任何"改进"。
//
// 接收行为摘要（与厂商版一致）：
//   * 前导码 7x0x55 + 0xD5（0x55 计数 >5 才认 D5，<=7）。
//   * 只接受 Ethernet II：ethertype == 0x0800；目的 MAC == local_mac
//     **或 == 广播 FF:FF:FF:FF:FF:FF**（厂商版接受广播，本模块照做）。
//   * IPv4：版本必须 4、**IHL 必须等于 5（不接受带选项的 IP 头）**、
//     协议必须 0x11(UDP)；**校验 IP 头 checksum**（复用厂商 ip_checksum）；
//     目的 IP 必须 == local_ip（**不接受广播 IP**——厂商就用等值比较）。
//   * UDP：只看目的端口 == local_port；**不校验 UDP 长度字段、不校验 UDP checksum**。
//   * 载荷长度 rx_data_length = IP总长 - 20 - 8（用 IP 总长，不是 UDP 长度字段）。
//   * 帧尾 **校验以太网 FCS**：全帧(dst MAC..FCS) CRC32 残差必须 == 0x2144DF1C，
//     否则 pkt_error=1。（复用 rtl/vendor_ref/eth_rx/crc32_d8.v，复位高有效。）
//   * data_overflow_i 语义与厂商一致：仅 RX_DATA 期间为高才把 pkt_error 置 1。
//
// 约束：本模块不使用 BUFG / IP / XPM，不使用 initial 给非存储元件赋值，
//       不使用 #delay 与 real。只用 Vivado 2018.3 支持的 SystemVerilog 子集。
//============================================================================
`timescale 1ns/1ps

module acx750_udp_rx (
  input  logic        clk,              // gmii_rx_clk 域（顶层已 BUFG）
  input  logic        reset,            // 高有效（与厂商版一致）

  input  logic [47:0] local_mac,
  input  logic [31:0] local_ip,
  input  logic [15:0] local_port,

  output logic [47:0] exter_mac,        // 对端(源)MAC
  output logic [31:0] exter_ip,         // 对端(源)IP
  output logic [15:0] exter_port,       // 对端(源)UDP端口
  output logic [15:0] rx_data_length,   // UDP 载荷长度

  input  logic        data_overflow_i,
  output logic        payload_valid_o,
  output logic [7:0]  payload_dat_o,

  output logic        one_pkt_done,
  output logic        pkt_error,

  input  logic [7:0]  gmii_rxd,
  input  logic        gmii_rxdv
);

  parameter ETH_type    = 16'h0800,
            IP_ver      = 4'h4,
            IP_hdr_len  = 4'h5,
            IP_protocol = 8'h11;

  localparam
    IDLE          = 9'b000000001,
    RX_PREAMBLE   = 9'b000000010,
    RX_ETH_HEADER = 9'b000000100,
    RX_IP_HEADER  = 9'b000001000,
    RX_UDP_HEADER = 9'b000010000,
    RX_DATA       = 9'b000100000,
    RX_DRP_DATA   = 9'b001000000,
    RX_CRC        = 9'b010000000,
    PKT_CHECK     = 9'b100000000;

  logic [7:0]  reg_gmii_rxd;
  logic        reg_gmii_rxdv;
  logic [7:0]  rx_data_dly1;
  logic [7:0]  rx_data_dly2;
  logic        rx_datav_dly1;
  logic        rx_datav_dly2;
  logic [47:0] local_mac_reg;
  logic [31:0] local_ip_reg;
  logic [15:0] local_port_reg;
  logic [8:0]  curr_state;
  logic [8:0]  next_state;

  logic        reg_data_overflow;

  logic [47:0] rx_dst_mac;
  logic [47:0] rx_src_mac;
  logic [15:0] rx_eth_type;
  logic        eth_header_check_ok;

  logic [3:0]  rx_ip_ver;
  logic [3:0]  rx_ip_hdr_len;
  logic [7:0]  rx_ip_tos;
  logic [15:0] rx_total_len;
  logic [15:0] rx_ip_id;
  logic        rx_ip_rsv;
  logic        rx_ip_df;
  logic        rx_ip_mf;
  logic [12:0] rx_ip_frag_offset;
  logic [7:0]  rx_ip_ttl;
  logic [7:0]  rx_ip_protocol;
  logic [15:0] rx_ip_check_sum;
  logic [31:0] rx_src_ip;
  logic [31:0] rx_dst_ip;
  logic        ip_checksum_cal_en;
  wire  [15:0] cal_check_sum;
  logic        ip_header_check_ok;

  logic [15:0] rx_src_port;
  logic [15:0] rx_dst_port;
  logic        udp_header_check_ok;

  logic        crc_init;
  logic        crc_en;
  logic [7:0]  crc_data;
  wire  [31:0] crc_check;

  logic [3:0]  cnt_preamble;
  logic [3:0]  cnt_eth_header;
  logic [4:0]  cnt_ip_header;
  logic [3:0]  cnt_udp_header;
  logic [15:0] cnt_data;
  logic [4:0]  cnt_drp_data;

  // 本地 MAC/IP/PORT 寄存器：仅在 IDLE 拍刷新（与厂商版一致）
  always @(posedge clk or posedge reset)
  if (reset) begin
    local_mac_reg  <= 48'h00_00_00_00_00_00;
    local_ip_reg   <= 32'h00_00_00_00;
    local_port_reg <= 16'h00_00;
  end
  else if (curr_state == IDLE) begin
    local_mac_reg  <= local_mac;
    local_ip_reg   <= local_ip;
    local_port_reg <= local_port;
  end

  // 以太网接收信号寄存
  always @(posedge clk or posedge reset)
  if (reset) begin
    reg_gmii_rxd  <= 8'h00;
    reg_gmii_rxdv <= 1'b0;
  end
  else begin
    reg_gmii_rxd  <= gmii_rxd;
    reg_gmii_rxdv <= gmii_rxdv;
  end

  // 接收信号再延两拍（状态机看 dly1/dly2）
  always @(posedge clk) begin
    rx_data_dly1  <= reg_gmii_rxd;
    rx_data_dly2  <= rx_data_dly1;
    rx_datav_dly1 <= reg_gmii_rxdv;
    rx_datav_dly2 <= rx_datav_dly1;
  end

  // cnt_preamble
  always @(posedge clk or posedge reset)
  if (reset)
    cnt_preamble <= 4'd0;
  else if (curr_state == RX_PREAMBLE && rx_data_dly2 == 8'h55)
    cnt_preamble <= cnt_preamble + 1'b1;
  else
    cnt_preamble <= 4'd0;

  // cnt_eth_header
  always @(posedge clk or posedge reset)
  if (reset)
    cnt_eth_header <= 4'd0;
  else if (curr_state == RX_ETH_HEADER)
    cnt_eth_header <= cnt_eth_header + 1'b1;
  else
    cnt_eth_header <= 4'd0;

  // eth_header
  always @(posedge clk or posedge reset)
  if (reset) begin
    rx_dst_mac  <= 48'h00_00_00_00_00_00;
    rx_src_mac  <= 48'h00_00_00_00_00_00;
    rx_eth_type <= 16'h0000;
  end
  else if (curr_state == RX_ETH_HEADER) begin
    case (cnt_eth_header)
      4'd0 : rx_dst_mac[47:40] <= rx_data_dly2;
      4'd1 : rx_dst_mac[39:32] <= rx_data_dly2;
      4'd2 : rx_dst_mac[31:24] <= rx_data_dly2;
      4'd3 : rx_dst_mac[23:16] <= rx_data_dly2;
      4'd4 : rx_dst_mac[15:8]  <= rx_data_dly2;
      4'd5 : rx_dst_mac[7:0]   <= rx_data_dly2;

      4'd6 : rx_src_mac[47:40] <= rx_data_dly2;
      4'd7 : rx_src_mac[39:32] <= rx_data_dly2;
      4'd8 : rx_src_mac[31:24] <= rx_data_dly2;
      4'd9 : rx_src_mac[23:16] <= rx_data_dly2;
      4'd10: rx_src_mac[15:8]  <= rx_data_dly2;
      4'd11: rx_src_mac[7:0]   <= rx_data_dly2;

      4'd12: rx_eth_type[15:8] <= rx_data_dly2;
      4'd13: rx_eth_type[7:0]  <= rx_data_dly2;
      default: ;
    endcase
  end
  else begin
    rx_dst_mac  <= rx_dst_mac;
    rx_src_mac  <= rx_src_mac;
    rx_eth_type <= rx_eth_type;
  end

  // 以太网头判定：ethertype==0x0800 且 (目的MAC==本地 或 广播) —— 与厂商一致
  always @(posedge clk or posedge reset)
  if (reset)
    eth_header_check_ok <= 1'b0;
  else if (rx_eth_type == ETH_type && (rx_dst_mac == local_mac_reg || rx_dst_mac == 48'hFF_FF_FF_FF_FF_FF))
    eth_header_check_ok <= 1'b1;
  else
    eth_header_check_ok <= 1'b0;

  // cnt_ip_header
  always @(posedge clk or posedge reset)
  if (reset)
    cnt_ip_header <= 5'd0;
  else if (curr_state == RX_IP_HEADER)
    cnt_ip_header <= cnt_ip_header + 1'b1;
  else
    cnt_ip_header <= 5'd0;

  // ip_header（固定按 20 字节读取；IHL!=5 的帧会在 UDP 阶段被判掉）
  always @(posedge clk or posedge reset)
  if (reset) begin
    {rx_ip_ver, rx_ip_hdr_len}     <= 8'h0;
    rx_ip_tos                      <= 8'h0;
    rx_total_len                   <= 16'h0;
    rx_ip_id                       <= 16'h0;
    {rx_ip_rsv, rx_ip_df, rx_ip_mf} <= 3'h0;
    rx_ip_frag_offset              <= 13'h0;
    rx_ip_ttl                      <= 8'h0;
    rx_ip_protocol                 <= 8'h0;
    rx_ip_check_sum                <= 16'h0;
    rx_src_ip                      <= 32'h0;
    rx_dst_ip                      <= 32'h0;
  end
  else if (curr_state == RX_IP_HEADER) begin
    case (cnt_ip_header)
      5'd0:  {rx_ip_ver, rx_ip_hdr_len}                             <= rx_data_dly2;
      5'd1:  rx_ip_tos                                              <= rx_data_dly2;
      5'd2:  rx_total_len[15:8]                                     <= rx_data_dly2;
      5'd3:  rx_total_len[7:0]                                      <= rx_data_dly2;
      5'd4:  rx_ip_id[15:8]                                         <= rx_data_dly2;
      5'd5:  rx_ip_id[7:0]                                          <= rx_data_dly2;
      5'd6:  {rx_ip_rsv, rx_ip_df, rx_ip_mf, rx_ip_frag_offset[12:8]} <= rx_data_dly2;
      5'd7:  rx_ip_frag_offset[7:0]                                 <= rx_data_dly2;
      5'd8:  rx_ip_ttl                                              <= rx_data_dly2;
      5'd9:  rx_ip_protocol                                         <= rx_data_dly2;
      5'd10: rx_ip_check_sum[15:8]                                  <= rx_data_dly2;
      5'd11: rx_ip_check_sum[7:0]                                   <= rx_data_dly2;
      5'd12: rx_src_ip[31:24]                                       <= rx_data_dly2;
      5'd13: rx_src_ip[23:16]                                       <= rx_data_dly2;
      5'd14: rx_src_ip[15:8]                                        <= rx_data_dly2;
      5'd15: rx_src_ip[7:0]                                         <= rx_data_dly2;
      5'd16: rx_dst_ip[31:24]                                       <= rx_data_dly2;
      5'd17: rx_dst_ip[23:16]                                       <= rx_data_dly2;
      5'd18: rx_dst_ip[15:8]                                        <= rx_data_dly2;
      5'd19: rx_dst_ip[7:0]                                         <= rx_data_dly2;
      default: ;
    endcase
  end

  // rx_data_length = IP总长 - IP头20 - UDP头8（与厂商一致：用 IP 总长）
  always @(posedge clk or posedge reset)
  if (reset)
    rx_data_length <= 16'd0;
  else if (curr_state == RX_IP_HEADER && cnt_ip_header == 5'd19)
    rx_data_length <= rx_total_len - 8'd20 - 8'd8;
  else
    rx_data_length <= rx_data_length;

  always @(posedge clk or posedge reset)
  if (reset)
    ip_checksum_cal_en <= 1'b0;
  else if (curr_state == RX_IP_HEADER && cnt_ip_header == 5'd19)
    ip_checksum_cal_en <= 1'b1;
  else
    ip_checksum_cal_en <= 1'b0;

  // IP 头 checksum：复用厂商 ip_checksum（行为一致）
  ip_checksum u_ip_checksum (
    .clk            (clk              ),
    .reset          (reset            ),
    .cal_en         (ip_checksum_cal_en),
    .IP_ver         (rx_ip_ver        ),
    .IP_hdr_len     (rx_ip_hdr_len    ),
    .IP_tos         (rx_ip_tos        ),
    .IP_total_len   (rx_total_len     ),
    .IP_id          (rx_ip_id         ),
    .IP_rsv         (rx_ip_rsv        ),
    .IP_df          (rx_ip_df         ),
    .IP_mf          (rx_ip_mf         ),
    .IP_frag_offset (rx_ip_frag_offset),
    .IP_ttl         (rx_ip_ttl        ),
    .IP_protocol    (rx_ip_protocol   ),
    .src_ip         (rx_src_ip        ),
    .dst_ip         (rx_dst_ip        ),
    .checksum       (cal_check_sum    )
  );

  // IP 头判定：版本/IHL(必须5)/协议(必须0x11)/checksum 全对；目的IP == 本地IP
  always @(posedge clk or posedge reset)
  if (reset)
    ip_header_check_ok <= 1'b0;
  else if ({IP_ver, IP_hdr_len, IP_protocol, cal_check_sum, local_ip_reg} ==
           {rx_ip_ver, rx_ip_hdr_len, rx_ip_protocol, rx_ip_check_sum, rx_dst_ip})
    ip_header_check_ok <= 1'b1;
  else
    ip_header_check_ok <= 1'b0;

  // cnt_udp_header
  always @(posedge clk or posedge reset)
  if (reset)
    cnt_udp_header <= 4'd0;
  else if (curr_state == RX_UDP_HEADER)
    cnt_udp_header <= cnt_udp_header + 1'b1;
  else
    cnt_udp_header <= 4'd0;

  always @(posedge clk or posedge reset)
  if (reset) begin
    rx_src_port  <= 16'h0;
    rx_dst_port  <= 16'h0;
  end
  else if (curr_state == RX_UDP_HEADER) begin
    case (cnt_udp_header)
      4'd0: rx_src_port[15:8] <= rx_data_dly2;
      4'd1: rx_src_port[7:0]  <= rx_data_dly2;
      4'd2: rx_dst_port[15:8] <= rx_data_dly2;
      4'd3: rx_dst_port[7:0]  <= rx_data_dly2;
      default: ;
    endcase
  end

  // UDP 头判定：只看目的端口（不校验 UDP 长度/checksum，与厂商一致）
  always @(posedge clk or posedge reset)
  if (reset)
    udp_header_check_ok <= 1'b0;
  else if (rx_dst_port == local_port_reg)
    udp_header_check_ok <= 1'b1;
  else
    udp_header_check_ok <= 1'b0;

  // cnt_data
  always @(posedge clk or posedge reset)
  if (reset)
    cnt_data <= 16'd0;
  else if (curr_state == RX_DATA)
    cnt_data <= cnt_data + 1'b1;
  else
    cnt_data <= 16'd0;

  // cnt_drp_data
  always @(posedge clk or posedge reset)
  if (reset)
    cnt_drp_data <= 5'd0;
  else if (curr_state == RX_DRP_DATA)
    cnt_drp_data <= cnt_drp_data + 1'b1;
  else
    cnt_drp_data <= 5'd0;

  // FSM
  always @(posedge clk or posedge reset)
  if (reset)
    curr_state <= IDLE;
  else
    curr_state <= next_state;

  always @(*) begin
    case (curr_state)
      IDLE:
        if (!rx_datav_dly2 && rx_datav_dly1)
          next_state = RX_PREAMBLE;
        else
          next_state = IDLE;

      RX_PREAMBLE:
        if (rx_data_dly2 == 8'hd5 && cnt_preamble > 4'd5)
          next_state = RX_ETH_HEADER;
        else if (cnt_preamble > 4'd7)
          next_state = IDLE;
        else
          next_state = RX_PREAMBLE;

      RX_ETH_HEADER:
        if (cnt_eth_header == 4'd13)
          next_state = RX_IP_HEADER;
        else
          next_state = RX_ETH_HEADER;

      RX_IP_HEADER:
        if (cnt_ip_header == 5'd2 && eth_header_check_ok == 1'b0)
          next_state = IDLE;
        else if (cnt_ip_header == 5'd19)
          next_state = RX_UDP_HEADER;
        else
          next_state = RX_IP_HEADER;

      RX_UDP_HEADER:
        if (cnt_udp_header == 4'd2 && ip_header_check_ok == 1'b0)
          next_state = IDLE;
        else if (cnt_udp_header == 4'd7 && udp_header_check_ok == 1'b0)
          next_state = IDLE;
        else if (cnt_udp_header == 4'd7)
          next_state = RX_DATA;
        else
          next_state = RX_UDP_HEADER;

      RX_DATA:
        if ((rx_data_length < 5'd18) && (cnt_data == rx_data_length - 1'b1))
          next_state = RX_DRP_DATA;
        else if (cnt_data == rx_data_length - 1'b1)
          next_state = RX_CRC;
        else
          next_state = RX_DATA;

      RX_DRP_DATA:
        if (cnt_drp_data == 5'd17 - rx_data_length)
          next_state = RX_CRC;
        else
          next_state = RX_DRP_DATA;

      RX_CRC:
        if (rx_datav_dly2 == 1'b0)
          next_state = PKT_CHECK;
        else
          next_state = RX_CRC;

      PKT_CHECK:
        next_state = IDLE;

      default: next_state = IDLE;
    endcase
  end

  always @(posedge clk or posedge reset)
  if (reset)
    crc_init <= 1'b0;
  else if (rx_datav_dly1 && (~rx_datav_dly2))
    crc_init <= 1'b1;
  else
    crc_init <= 1'b0;

  // crc_en
  always @(posedge clk or posedge reset)
  if (reset)
    crc_en <= 1'b0;
  else if (curr_state == IDLE)
    crc_en <= 1'b0;
  else if (curr_state != RX_PREAMBLE && rx_datav_dly2)
    crc_en <= 1'b1;
  else
    crc_en <= 1'b0;

  // crc_data
  always @(posedge clk or posedge reset)
  if (reset)
    crc_data <= 8'd0;
  else
    crc_data <= rx_data_dly2;

  // FCS：复用厂商接收版 crc32_d8（复位 reset 高有效，latency=1）
  crc32_d8 u_crc32_d8 (
    .clk        (clk      ),
    .reset      (reset    ),
    .data       (crc_data ),
    .crc_init   (crc_init ),
    .crc_en     (crc_en   ),
    .crc_result (crc_check)
  );

  always @(posedge clk or posedge reset)
  if (reset)
    reg_data_overflow <= 1'b0;
  else if (curr_state == IDLE)
    reg_data_overflow <= 1'b0;
  else if (curr_state == RX_DATA && data_overflow_i == 1'b1)
    reg_data_overflow <= 1'b1;
  else
    reg_data_overflow <= reg_data_overflow;

  // payload output
  always @(posedge clk or posedge reset)
  if (reset) begin
    payload_valid_o <= 1'b0;
    payload_dat_o   <= 8'h0;
  end
  else if (curr_state == RX_DATA) begin
    payload_valid_o <= 1'b1;
    payload_dat_o   <= rx_data_dly2;
  end
  else begin
    payload_valid_o <= 1'b0;
    payload_dat_o   <= 8'h0;
  end

  always @(posedge clk or posedge reset)
  if (reset) begin
    exter_mac  <= 48'h0;
    exter_ip   <= 32'h0;
    exter_port <= 16'h0;
  end
  else if (curr_state == PKT_CHECK) begin
    exter_mac  <= rx_src_mac;
    exter_ip   <= rx_src_ip;
    exter_port <= rx_src_port;
  end

  // done / error
  always @(posedge clk or posedge reset)
  if (reset) begin
    one_pkt_done <= 1'b0;
    pkt_error    <= 1'b0;
  end
  else if (curr_state == PKT_CHECK) begin
    one_pkt_done <= 1'b1;
    if (crc_check == 32'h2144DF1C && reg_data_overflow == 1'b0)
      pkt_error  <= 1'b0;
    else
      pkt_error  <= 1'b1;
  end
  else begin
    one_pkt_done <= 1'b0;
    pkt_error    <= 1'b0;
  end

endmodule