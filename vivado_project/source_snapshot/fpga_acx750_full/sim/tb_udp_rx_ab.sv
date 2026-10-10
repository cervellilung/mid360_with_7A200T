//============================================================================
// tb_udp_rx_ab -- acx750_udp_rx 与厂商 eth_udp_rx_gmii 的 A/B 对拍
//
// 目的（见 docs/known_gaps.md G8）：
//   同时例化自写版 `acx750_udp_rx` 与厂商版 `eth_udp_rx_gmii`，用**同一份
//   GMII 刺激**驱动，逐拍比对全部可观测输出：
//       payload_valid_o / payload_dat_o / one_pkt_done / pkt_error /
//       rx_data_length / exter_mac / exter_ip / exter_port
//   任何一拍不一致立即打印 MISMATCH（含语料号与载荷字节序），并对若干正常包
//   额外断言逐字节期望值。13 条语料全部跑完且 A/B 完全一致 + 期望全对才 PASS。
//
// 说明：
//   * 厂商版内部自带 BUFG，仿真时需要 `-L unisims_ver` 与 `glbl`（见报告）。
//   * 两个被测模块的 local_mac/local_ip/local_port 输入完全相同；local_port 在
//     语料 2 期间临时置为 56300，跑完恢复 56301（厂商与自写版都在 IDLE 拍刷新
//     本地寄存器，行为一致）。
//   * gmii_rxd/gmii_rxdv 在 clk 下降沿改变、上升沿被采样，避免组合竞争。
//   * 以太网 FCS 用标准 CRC32(IEEE802.3) 计算，小端附加。
//============================================================================
`timescale 1ns/1ps

module tb_udp_rx_ab;

  //--------------------------------------------------------------------------
  // 时钟与复位
  //--------------------------------------------------------------------------
  reg clk = 1'b0;
  always #4 clk = ~clk;            // 125 MHz，周期 8ns

  reg reset = 1'b1;

  //--------------------------------------------------------------------------
  // 本地地址参数
  //--------------------------------------------------------------------------
  localparam [47:0] PL_MAC     = 48'h00_0a_35_01_fe_c0;
  localparam [31:0] PL_IP      = 32'hC0A8_0132;   // 192.168.1.50
  localparam [47:0] RADAR_MAC  = 48'h00_1E_06_11_22_33;
  localparam [31:0] RADAR_IP   = 32'hC0A8_0114;   // 192.168.1.20
  localparam [15:0] RADAR_PORT = 16'd56300;       // 雷达源端口
  localparam [47:0] RASPI_MAC  = 48'hDC_A6_32_44_55_66;
  localparam [31:0] RASPI_IP   = 32'hC0A8_010A;   // 192.168.1.10
  localparam [15:0] RASPI_PORT = 16'd40000;

  reg [47:0] local_mac;
  reg [31:0] local_ip;
  reg [15:0] local_port;

  reg  [7:0] gmii_rxd  = 8'h00;
  reg        gmii_rxdv = 1'b0;

  //--------------------------------------------------------------------------
  // 自写版输出
  //--------------------------------------------------------------------------
  wire [47:0] n_exter_mac;
  wire [31:0] n_exter_ip;
  wire [15:0] n_exter_port;
  wire [15:0] n_len;
  wire        n_pv;
  wire [7:0]  n_pd;
  wire        n_done;
  wire        n_err;

  //--------------------------------------------------------------------------
  // 厂商版输出
  //--------------------------------------------------------------------------
  wire        v_clk125m_o;
  wire [47:0] v_exter_mac;
  wire [31:0] v_exter_ip;
  wire [15:0] v_exter_port;
  wire [15:0] v_len;
  wire        v_pv;
  wire [7:0]  v_pd;
  wire        v_done;
  wire        v_err;
  wire [31:0] v_crc;

  acx750_udp_rx u_new (
    .clk            (clk         ),
    .reset          (reset       ),
    .local_mac      (local_mac   ),
    .local_ip       (local_ip    ),
    .local_port     (local_port  ),
    .exter_mac      (n_exter_mac ),
    .exter_ip       (n_exter_ip  ),
    .exter_port     (n_exter_port),
    .rx_data_length (n_len       ),
    .data_overflow_i(1'b0        ),
    .payload_valid_o(n_pv        ),
    .payload_dat_o  (n_pd        ),
    .one_pkt_done   (n_done      ),
    .pkt_error      (n_err       ),
    .gmii_rxd       (gmii_rxd    ),
    .gmii_rxdv      (gmii_rxdv   )
  );

  eth_udp_rx_gmii u_vnd (
    .reset          (reset       ),
    .local_mac      (local_mac   ),
    .local_ip       (local_ip    ),
    .local_port     (local_port  ),
    .clk125m_o      (v_clk125m_o ),
    .exter_mac      (v_exter_mac ),
    .exter_ip       (v_exter_ip  ),
    .exter_port     (v_exter_port),
    .rx_data_length (v_len       ),
    .data_overflow_i(1'b0        ),
    .payload_valid_o(v_pv        ),
    .payload_dat_o  (v_pd        ),
    .one_pkt_done   (v_done      ),
    .pkt_error      (v_err       ),
    .debug_crc_check(v_crc       ),
    .gmii_rx_clk    (clk         ),
    .gmii_rxd       (gmii_rxd    ),
    .gmii_rxdv      (gmii_rxdv   )
  );

  //--------------------------------------------------------------------------
  // 帧缓冲与工具函数
  //--------------------------------------------------------------------------
  reg [7:0] FRM [0:511];
  integer   FLEN;
  reg [7:0] IPH [0:23];

  // 标准以太网 CRC32（反射，多项式 0xEDB88320）
  function [31:0] crc32_upd;
    input [31:0] c;
    input [7:0]  b;
    integer i;
    reg [31:0] cc;
    begin
      cc = c ^ {24'h0, b};
      for (i = 0; i < 8; i = i + 1)
        cc = cc[0] ? ((cc >> 1) ^ 32'hEDB88320) : (cc >> 1);
      crc32_upd = cc;
    end
  endfunction

  // IP 头 ones-complement 校验和（对 IPH[0..n-1]，校验和字段已置 0）
  function [15:0] ones_csum;
    input integer n;
    integer i;
    reg [31:0] s;
    begin
      s = 32'd0;
      for (i = 0; i < n; i = i + 2)
        s = s + {16'd0, IPH[i], IPH[i+1]};
      while (s[31:16] != 0)
        s = (s & 32'h0000_FFFF) + (s >> 16);
      ones_csum = ~s[15:0];
    end
  endfunction

  //--------------------------------------------------------------------------
  // 造一帧（写入 FRM，长度写入 FLEN；含 FCS）
  //--------------------------------------------------------------------------
  integer csum_i;
  reg [15:0] csum;
  integer tot_i, ihl_i, ulen_i;

  task build_frame;
    input [47:0] dmac;
    input [47:0] smac;
    input [15:0] etype;
    input [7:0]  proto;
    input [3:0]  ihl;
    input [31:0] sip;
    input [31:0] dip;
    input [15:0] sport;
    input [15:0] dport;
    input integer plen;
    input integer pseed;
    input integer badfcs;
    integer i;
    reg [31:0] c, fcs;
    begin
      FRM[0]=dmac[47:40]; FRM[1]=dmac[39:32]; FRM[2]=dmac[31:24];
      FRM[3]=dmac[23:16]; FRM[4]=dmac[15:8];  FRM[5]=dmac[7:0];
      FRM[6]=smac[47:40]; FRM[7]=smac[39:32]; FRM[8]=smac[31:24];
      FRM[9]=smac[23:16]; FRM[10]=smac[15:8]; FRM[11]=smac[7:0];
      FRM[12]=etype[15:8]; FRM[13]=etype[7:0];

      ihl_i = ihl * 4;
      ulen_i = 8 + plen;
      tot_i  = ihl_i + ulen_i;

      IPH[0] = {4'h4, ihl};
      IPH[1] = 8'h00;
      IPH[2] = tot_i[15:8];  IPH[3] = tot_i[7:0];
      IPH[4] = 8'h00;        IPH[5] = 8'h00;
      IPH[6] = 8'h00;        IPH[7] = 8'h00;
      IPH[8] = 8'd64;
      IPH[9] = proto;
      IPH[10]= 8'h00;        IPH[11]= 8'h00;   // 校验和占位
      IPH[12]=sip[31:24]; IPH[13]=sip[23:16]; IPH[14]=sip[15:8]; IPH[15]=sip[7:0];
      IPH[16]=dip[31:24]; IPH[17]=dip[23:16]; IPH[18]=dip[15:8]; IPH[19]=dip[7:0];
      if (ihl == 4'd6) begin                    // 4 字节选项（Router Alert）
        IPH[20]=8'h94; IPH[21]=8'h04; IPH[22]=8'h00; IPH[23]=8'h00;
      end
      csum = ones_csum(ihl_i);
      IPH[10] = csum[15:8]; IPH[11] = csum[7:0];

      for (i = 0; i < ihl_i; i = i + 1)
        FRM[14+i] = IPH[i];

      FRM[14+ihl_i+0] = sport[15:8];
      FRM[14+ihl_i+1] = sport[7:0];
      FRM[14+ihl_i+2] = dport[15:8];
      FRM[14+ihl_i+3] = dport[7:0];
      FRM[14+ihl_i+4] = ulen_i[15:8];
      FRM[14+ihl_i+5] = ulen_i[7:0];
      FRM[14+ihl_i+6] = 8'h00;   // UDP 校验和 = 0（DUT 不校验）
      FRM[14+ihl_i+7] = 8'h00;

      for (i = 0; i < plen; i = i + 1)
        FRM[14+ihl_i+8+i] = (pseed + i) & 8'hFF;

      FLEN = 14 + ihl_i + 8 + plen;

      c = 32'hFFFF_FFFF;
      for (i = 0; i < FLEN; i = i + 1)
        c = crc32_upd(c, FRM[i]);
      fcs = ~c;
      if (badfcs) fcs = fcs ^ 32'h0000_0001;   // 故意写错 FCS

      FRM[FLEN+0] = fcs[7:0];
      FRM[FLEN+1] = fcs[15:8];
      FRM[FLEN+2] = fcs[23:16];
      FRM[FLEN+3] = fcs[31:24];
      FLEN = FLEN + 4;
    end
  endtask

  //--------------------------------------------------------------------------
  // GMII 字节发送（下降沿置数，上升沿被采样）
  //--------------------------------------------------------------------------
  integer IFG = 8;

  task putb;
    input [7:0] b;
    begin
      @(negedge clk);
      gmii_rxdv = 1'b1;
      gmii_rxd  = b;
    end
  endtask

  task send_frame_bytes;
    input integer n;              // 送 FRM[0..n-1]，自动加前导码，末尾拉低并留 IFG
    integer i;
    begin
      for (i = 0; i < 7; i = i + 1) putb(8'h55);
      putb(8'hD5);
      for (i = 0; i < n; i = i + 1) putb(FRM[i]);
      @(negedge clk);
      gmii_rxdv = 1'b0;
      gmii_rxd  = 8'h00;
      for (i = 0; i < IFG; i = i + 1) @(negedge clk);
    end
  endtask

  task settle;
    input integer n;
    integer i;
    begin
      for (i = 0; i < n; i = i + 1) @(negedge clk);
    end
  endtask

  //--------------------------------------------------------------------------
  // 对拍与记录
  //--------------------------------------------------------------------------
  integer errs;
  integer corpus;        // 0 基
  integer pbyte;         // 本语料内自写版已输出的载荷字节数（用于定位）
  integer got_n;
  reg [7:0] got [0:90000];
  integer done_cnt;      // 自写版本语料 done 次数
  integer err_cnt;       // 自写版本语料 pkt_error=1 的次数
  reg [47:0] xmac;
  reg [31:0] xip;
  reg [15:0] xport;
  reg [15:0] xlen;
  reg cmp_en;

  always @(posedge clk) begin
    if (cmp_en) begin
      if (n_pv !== v_pv || n_pd !== v_pd || n_done !== v_done || n_err !== v_err ||
          n_len !== v_len || n_exter_mac !== v_exter_mac ||
          n_exter_ip !== v_exter_ip || n_exter_port !== v_exter_port) begin
        errs = errs + 1;
        if (errs <= 60)
          $display("MISMATCH 语料=%0d 字节序=%0d @%0t : pv %b/%b pd %02x/%02x done %b/%b err %b/%b len %0d/%0d mac %012x/%012x ip %08x/%08x port %0d/%0d",
                   corpus+1, pbyte, $time,
                   n_pv,v_pv, n_pd,v_pd, n_done,v_done, n_err,v_err, n_len,v_len,
                   n_exter_mac,v_exter_mac, n_exter_ip,v_exter_ip, n_exter_port,v_exter_port);
      end

      if (n_pv) begin
        if (got_n < 90000) got[got_n] = n_pd;
        got_n  = got_n + 1;
        pbyte  = pbyte + 1;
      end
      if (n_done) begin
        done_cnt = done_cnt + 1;
        err_cnt  = err_cnt + (n_err ? 1 : 0);
        xmac = n_exter_mac; xip = n_exter_ip; xport = n_exter_port; xlen = n_len;
      end
    end
  end

  task begin_corpus;
    input integer id;
    begin
      corpus = id; pbyte = 0; got_n = 0; done_cnt = 0; err_cnt = 0;
    end
  endtask

  // 期望：接受（done=1, error=0，载荷逐字节正确，exter 正确）
  task check_accept;
    input integer id_prn;
    input integer elen;
    input integer eseed;
    input [47:0] esmac;
    input [31:0] esip;
    input [15:0] esport;
    integer k;
    begin
      if (done_cnt != 1) begin
        errs = errs + 1; $display("FAIL 语料%0d: done=%0d（期望 1）", id_prn, done_cnt);
      end
      if (err_cnt != 0) begin
        errs = errs + 1; $display("FAIL 语料%0d: pkt_error 出现 %0d 次（期望 0）", id_prn, err_cnt);
      end
      if (got_n != elen) begin
        errs = errs + 1; $display("FAIL 语料%0d: 载荷字节数 %0d（期望 %0d）", id_prn, got_n, elen);
      end else begin
        for (k = 0; k < elen; k = k + 1)
          if (got[k] !== ((eseed + k) & 8'hFF)) begin
            errs = errs + 1;
            if (errs <= 60) $display("FAIL 语料%0d 载荷字节%0d: got=%02x exp=%02x",
                                     id_prn, k, got[k], (eseed + k) & 8'hFF);
          end
      end
      if (xlen !== elen[15:0]) begin
        errs = errs + 1; $display("FAIL 语料%0d: rx_data_length=%0d（期望 %0d）", id_prn, xlen, elen);
      end
      if (xmac !== esmac || xip !== esip || xport !== esport) begin
        errs = errs + 1;
        $display("FAIL 语料%0d: exter=%012x/%08x/%0d（期望 %012x/%08x/%0d）",
                 id_prn, xmac, xip, xport, esmac, esip, esport);
      end
    end
  endtask

  // 期望：拒绝（无 done，无载荷）
  task check_reject;
    input integer id_prn;
    begin
      if (done_cnt != 0) begin
        errs = errs + 1; $display("FAIL 语料%0d: 出现 done %0d 次（期望拒绝 0）", id_prn, done_cnt);
      end
      if (got_n != 0) begin
        errs = errs + 1; $display("FAIL 语料%0d: 出现载荷 %0d 字节（期望 0）", id_prn, got_n);
      end
    end
  endtask

  //--------------------------------------------------------------------------
  // 刺激
  //--------------------------------------------------------------------------
  initial begin
    errs = 0; corpus = 0; pbyte = 0; got_n = 0; done_cnt = 0; err_cnt = 0;
    cmp_en = 0;
    local_mac  = PL_MAC;
    local_ip   = PL_IP;
    local_port = 16'd56301;        // 点云端口

    reset = 1'b1;
    gmii_rxdv = 1'b0; gmii_rxd = 8'h00;
    repeat (10) @(negedge clk);
    reset = 1'b0;
    repeat (10) @(negedge clk);
    cmp_en = 1'b1;

    //======================================================================
    // 语料 1：正常点云包（目的端口 56301，目的 IP=PL，载荷 32B）
    //======================================================================
    settle(20);
    begin_corpus(0);
    build_frame(PL_MAC, RADAR_MAC, 16'h0800, 8'h11, 4'd5,
                RADAR_IP, PL_IP, RADAR_PORT, 16'd56301, 32, 8'hA0, 0);
    send_frame_bytes(FLEN);
    settle(40);
    $display("[语料 1] 正常点云包(56301) : done=%0d err=%0d 载荷=%0d rx_len=%0d exter=%012x/%08x/%0d",
             done_cnt, err_cnt, got_n, xlen, xmac, xip, xport);
    check_accept(1, 32, 8'hA0, RADAR_MAC, RADAR_IP, RADAR_PORT);

    //======================================================================
    // 语料 2：正常配置包（目的端口 56300）
    //======================================================================
    settle(20);
    local_port = 16'd56300;        // 临时切到配置端口（IDLE 拍刷新）
    settle(8);
    begin_corpus(1);
    build_frame(PL_MAC, RASPI_MAC, 16'h0800, 8'h11, 4'd5,
                RASPI_IP, PL_IP, RASPI_PORT, 16'd56300, 8, 8'h30, 0);
    send_frame_bytes(FLEN);
    settle(40);
    $display("[语料 2] 正常配置包(56300) : done=%0d err=%0d 载荷=%0d rx_len=%0d exter=%012x/%08x/%0d",
             done_cnt, err_cnt, got_n, xlen, xmac, xip, xport);
    check_accept(2, 8, 8'h30, RASPI_MAC, RASPI_IP, RASPI_PORT);
    local_port = 16'd56301;        // 恢复点云端口
    settle(8);

    //======================================================================
    // 语料 3：目的端口不对
    //======================================================================
    settle(20);
    begin_corpus(2);
    build_frame(PL_MAC, RADAR_MAC, 16'h0800, 8'h11, 4'd5,
                RADAR_IP, PL_IP, RADAR_PORT, 16'd56302, 16, 8'h40, 0);
    send_frame_bytes(FLEN);
    settle(40);
    $display("[语料 3] 目的端口不对    : done=%0d 载荷=%0d", done_cnt, got_n);
    check_reject(3);

    //======================================================================
    // 语料 4：目的 IP 不对
    //======================================================================
    settle(20);
    begin_corpus(3);
    build_frame(PL_MAC, RADAR_MAC, 16'h0800, 8'h11, 4'd5,
                RADAR_IP, 32'hC0A8_0163, RADAR_PORT, 16'd56301, 16, 8'h41, 0);
    send_frame_bytes(FLEN);
    settle(40);
    $display("[语料 4] 目的 IP 不对     : done=%0d 载荷=%0d", done_cnt, got_n);
    check_reject(4);

    //======================================================================
    // 语料 5：目的 MAC 不对
    //======================================================================
    settle(20);
    begin_corpus(4);
    build_frame(48'h11_22_33_44_55_66, RADAR_MAC, 16'h0800, 8'h11, 4'd5,
                RADAR_IP, PL_IP, RADAR_PORT, 16'd56301, 16, 8'h42, 0);
    send_frame_bytes(FLEN);
    settle(40);
    $display("[语料 5] 目的 MAC 不对    : done=%0d 载荷=%0d", done_cnt, got_n);
    check_reject(5);

    //======================================================================
    // 语料 6：非 UDP（协议 0x06）
    //======================================================================
    settle(20);
    begin_corpus(5);
    build_frame(PL_MAC, RADAR_MAC, 16'h0800, 8'h06, 4'd5,
                RADAR_IP, PL_IP, RADAR_PORT, 16'd56301, 16, 8'h43, 0);
    send_frame_bytes(FLEN);
    settle(40);
    $display("[语料 6] 非 UDP(proto=0x06): done=%0d 载荷=%0d", done_cnt, got_n);
    check_reject(6);

    //======================================================================
    // 语料 7：非 IPv4（ethertype 0x0806 = ARP）
    //======================================================================
    settle(20);
    begin_corpus(6);
    build_frame(PL_MAC, RADAR_MAC, 16'h0806, 8'h11, 4'd5,
                RADAR_IP, PL_IP, RADAR_PORT, 16'd56301, 16, 8'h44, 0);
    send_frame_bytes(FLEN);
    settle(40);
    $display("[语料 7] 非 IPv4(0x0806) : done=%0d 载荷=%0d", done_cnt, got_n);
    check_reject(7);

    //======================================================================
    // 语料 8：FCS 故意写错
    //======================================================================
    settle(20);
    begin_corpus(7);
    build_frame(PL_MAC, RADAR_MAC, 16'h0800, 8'h11, 4'd5,
                RADAR_IP, PL_IP, RADAR_PORT, 16'd56301, 16, 8'h50, 1);
    send_frame_bytes(FLEN);
    settle(40);
    $display("[语料 8] FCS 写错        : done=%0d err=%0d 载荷=%0d rx_len=%0d",
             done_cnt, err_cnt, got_n, xlen);
    // 结构上仍是合法 UDP 包：应 done=1 且 pkt_error=1，载荷逐字节正确
    if (done_cnt != 1) begin errs=errs+1; $display("FAIL 语料8: done=%0d（期望 1）", done_cnt); end
    if (err_cnt  != 1) begin errs=errs+1; $display("FAIL 语料8: pkt_error 次数=%0d（期望 1）", err_cnt); end
    if (got_n != 16)   begin errs=errs+1; $display("FAIL 语料8: 载荷字节数=%0d（期望 16）", got_n); end
    else begin
      for (csum_i = 0; csum_i < 16; csum_i = csum_i + 1)
        if (got[csum_i] !== ((8'h50 + csum_i) & 8'hFF)) begin
          errs=errs+1; $display("FAIL 语料8 载荷字节%0d: got=%02x exp=%02x",
                                csum_i, got[csum_i], (8'h50+csum_i)&8'hFF);
        end
    end

    //======================================================================
    // 语料 9：截断帧（IP 头中间拉低 rxdv）
    //======================================================================
    settle(20);
    begin_corpus(8);
    build_frame(PL_MAC, RADAR_MAC, 16'h0800, 8'h11, 4'd5,
                RADAR_IP, PL_IP, RADAR_PORT, 16'd56301, 16, 8'h60, 0);
    send_frame_bytes(24);          // 只发以太网头 14 + IP 头前 10
    settle(60);
    $display("[语料 9] 截断帧          : done=%0d 载荷=%0d", done_cnt, got_n);
    check_reject(9);

    //======================================================================
    // 语料 10：超短帧（不足以太网头）
    //======================================================================
    settle(20);
    begin_corpus(9);
    build_frame(PL_MAC, RADAR_MAC, 16'h0800, 8'h11, 4'd5,
                RADAR_IP, PL_IP, RADAR_PORT, 16'd56301, 16, 8'h61, 0);
    send_frame_bytes(10);          // 不足 14 字节以太网头
    settle(60);
    $display("[语料 10] 超短帧         : done=%0d 载荷=%0d", done_cnt, got_n);
    check_reject(10);

    //======================================================================
    // 语料 11：长度 0 的 UDP 载荷
    //   （厂商版对 rx_data_length<18 的处理会在 RX_DATA 驻留到 cnt_data 绕回，
    //     此处只断言 A/B 一致与最终 done 完成，具体驻留行为见文档）
    //======================================================================
    settle(20);
    begin_corpus(10);
    build_frame(PL_MAC, RADAR_MAC, 16'h0800, 8'h11, 4'd5,
                RADAR_IP, PL_IP, RADAR_PORT, 16'd56301, 0, 8'h00, 0);
    send_frame_bytes(FLEN);
    wait (done_cnt == 1);          // 等 FSM 走完超长驻留
    settle(40);
    $display("[语料 11] 长度0的UDP载荷: done=%0d err=%0d 载荷=%0d rx_len=%0d",
             done_cnt, err_cnt, got_n, xlen);
    if (done_cnt != 1) begin errs=errs+1; $display("FAIL 语料11: done=%0d（期望 1）", done_cnt); end
    if (xlen !== 16'd0) begin errs=errs+1; $display("FAIL 语料11: rx_data_length=%0d（期望 0）", xlen); end

    //======================================================================
    // 语料 12：两帧背靠背连续发
    //======================================================================
    settle(40);
    begin_corpus(11);
    build_frame(PL_MAC, RADAR_MAC, 16'h0800, 8'h11, 4'd5,
                RADAR_IP, PL_IP, RADAR_PORT, 16'd56301, 16, 8'h70, 0);
    send_frame_bytes(FLEN);
    build_frame(PL_MAC, RADAR_MAC, 16'h0800, 8'h11, 4'd5,
                RADAR_IP, PL_IP, RADAR_PORT, 16'd56301, 24, 8'h90, 0);
    send_frame_bytes(FLEN);
    settle(60);
    $display("[语料 12] 背靠背两帧     : done=%0d err=%0d 载荷=%0d（期望 40）", done_cnt, err_cnt, got_n);
    if (done_cnt != 2) begin errs=errs+1; $display("FAIL 语料12: done=%0d（期望 2）", done_cnt); end
    if (err_cnt  != 0) begin errs=errs+1; $display("FAIL 语料12: pkt_error 次数=%0d（期望 0）", err_cnt); end
    if (got_n != 40)   begin errs=errs+1; $display("FAIL 语料12: 载荷字节数=%0d（期望 40）", got_n); end
    else begin
      for (csum_i = 0; csum_i < 16; csum_i = csum_i + 1)
        if (got[csum_i] !== ((8'h70 + csum_i) & 8'hFF)) begin
          errs=errs+1; $display("FAIL 语料12 帧1字节%0d: got=%02x exp=%02x",
                                csum_i, got[csum_i], (8'h70+csum_i)&8'hFF);
        end
      for (csum_i = 0; csum_i < 24; csum_i = csum_i + 1)
        if (got[16+csum_i] !== ((8'h90 + csum_i) & 8'hFF)) begin
          errs=errs+1; $display("FAIL 语料12 帧2字节%0d: got=%02x exp=%02x",
                                csum_i, got[16+csum_i], (8'h90+csum_i)&8'hFF);
        end
    end

    //======================================================================
    // 语料 13：IP 头带选项（IHL=6）
    //======================================================================
    settle(30);
    begin_corpus(12);
    build_frame(PL_MAC, RADAR_MAC, 16'h0800, 8'h11, 4'd6,
                RADAR_IP, PL_IP, RADAR_PORT, 16'd56301, 16, 8'hB0, 0);
    send_frame_bytes(FLEN);
    settle(40);
    $display("[语料 13] IP头带选项(IHL=6): done=%0d 载荷=%0d", done_cnt, got_n);
    check_reject(13);

    //======================================================================
    // 汇总
    //======================================================================
    $display("-----------------------------------------------------------");
    $display("A/B 对拍完成：13 条语料，MISMATCH/期望失配 总计 = %0d", errs);
    if (errs == 0) $display("PASS tb_udp_rx_ab");
    else           $display("FAIL tb_udp_rx_ab: errors=%0d", errs);
    $finish;
  end

  // 兜底超时
  initial begin
    #5000000;
    $display("FAIL tb_udp_rx_ab: timeout");
    $finish;
  end

endmodule