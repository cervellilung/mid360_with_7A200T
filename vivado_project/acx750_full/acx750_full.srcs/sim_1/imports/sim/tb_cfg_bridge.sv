























`timescale 1ns/1ps

module tb_cfg_bridge;

  
  
  
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;                       

  
  
  
  
  logic [7:0] cfg_data = 8'h0;
  logic       cfg_valid = 1'b0;
  logic       cfg_last  = 1'b0;

  
  logic [11:0] awaddr, araddr;
  logic [2:0]  awprot, arprot;
  logic        awvalid, awready, wvalid, wready, bvalid, bready;
  logic [31:0] wdata, rdata;
  logic [3:0]  wstrb;
  logic [1:0]  bresp, rresp;
  logic        arvalid, arready, rvalid, rready;

  
  logic [2047:0] config_words;
  logic [31:0] lut_word;
  logic          config_pending, config_safe = 1'b0;
  logic          snapshot_start = 1'b0, snapshot_busy;
  logic [1023:0] metadata = 1024'h0;
  logic [383:0]  object_data = 384'h0;
  logic [4:0]    object_index;

  
  logic [31:0] rb_word_index, rb_value;
  logic        rb_valid;
  logic [31:0] cfg_pkt_cnt, cfg_bad_cnt;

  acx750_cfg_bridge u_bridge (
    .clk            (clk),
    .rst_n          (rst_n),
    .cfg_data       (cfg_data),
    .cfg_valid      (cfg_valid),
    .cfg_last       (cfg_last),
    .m_axi_awaddr   (awaddr),
    .m_axi_awprot   (awprot),
    .m_axi_awvalid  (awvalid),
    .m_axi_awready  (awready),
    .m_axi_wdata    (wdata),
    .m_axi_wstrb    (wstrb),
    .m_axi_wvalid   (wvalid),
    .m_axi_wready   (wready),
    .m_axi_bresp    (bresp),
    .m_axi_bvalid   (bvalid),
    .m_axi_bready   (bready),
    .m_axi_araddr   (araddr),
    .m_axi_arprot   (arprot),
    .m_axi_arvalid  (arvalid),
    .m_axi_arready  (arready),
    .m_axi_rdata    (rdata),
    .m_axi_rresp    (rresp),
    .m_axi_rvalid   (rvalid),
    .m_axi_rready   (rready),
    .rb_word_index  (rb_word_index),
    .rb_value       (rb_value),
    .rb_valid       (rb_valid),
    .cfg_pkt_cnt    (cfg_pkt_cnt),
    .cfg_bad_cnt    (cfg_bad_cnt)
  );

  perception_regs u_regs (
    .s_axi_aclk     (clk),
    .s_axi_aresetn  (rst_n),
    .s_axi_awaddr   (awaddr),
    .s_axi_awprot   (awprot),
    .s_axi_awvalid  (awvalid),
    .s_axi_awready  (awready),
    .s_axi_wdata    (wdata),
    .s_axi_wstrb    (wstrb),
    .s_axi_wvalid   (wvalid),
    .s_axi_wready   (wready),
    .s_axi_bresp    (bresp),
    .s_axi_bvalid   (bvalid),
    .s_axi_bready   (bready),
    .s_axi_araddr   (araddr),
    .s_axi_arprot   (arprot),
    .s_axi_arvalid  (arvalid),
    .s_axi_arready  (arready),
    .s_axi_rdata    (rdata),
    .s_axi_rresp    (rresp),
    .s_axi_rvalid   (rvalid),
    .s_axi_rready   (rready),
    .config_words   (config_words),
    .lut_index      (8'd0), .lut_word(lut_word),
    .config_pending (config_pending),
    .config_safe    (config_safe),
    .snapshot_start (snapshot_start),
    .metadata       (metadata),
    .object_data    (object_data),
    .object_index   (object_index),
    .snapshot_busy  (snapshot_busy)
  );

  
  
  
  int          rb_pulses   = 0;
  logic [31:0] last_rb_idx = 32'h0;
  logic [31:0] last_rb_val = 32'h0;
  always_ff @(posedge clk) begin
    if (rb_valid) begin
      rb_pulses   <= rb_pulses + 1;
      last_rb_idx <= rb_word_index;
      last_rb_val <= rb_value;
    end
  end

  
  
  
  int  errors = 0;
  task automatic check(input bit cond, input string msg);
    if (!cond) begin
      errors = errors + 1;
      $display("FAIL cfg_bridge: %s", msg);
    end
  endtask

  
  logic [7:0] pkt [0:255];
  task automatic send_pkt(input int len);
    integer i;
    begin
      for (i = 0; i < len; i = i + 1) begin
        @(negedge clk);
        cfg_data  = pkt[i];
        cfg_valid = 1'b1;
        cfg_last  = (i == len - 1);
      end
      @(negedge clk);
      cfg_valid = 1'b0;
      cfg_last  = 1'b0;
    end
  endtask

  
  task automatic build_wr1(input [15:0] widx, input [31:0] val);
    begin
      pkt[0] = 8'h01; pkt[1] = 8'h01; pkt[2] = 8'h00; pkt[3] = 8'h00;
      pkt[4] = widx[7:0];  pkt[5] = widx[15:8];
      pkt[6] = val[7:0];   pkt[7] = val[15:8];
      pkt[8] = val[23:16]; pkt[9] = val[31:24];
    end
  endtask

  
  task automatic build_rd1(input [15:0] widx);
    begin
      pkt[0] = 8'h02; pkt[1] = 8'h01; pkt[2] = 8'h00; pkt[3] = 8'h00;
      pkt[4] = widx[7:0]; pkt[5] = widx[15:8];
    end
  endtask

  
  task automatic wait_change();
    logic [31:0] p0, b0;
    integer      g;
    begin
      p0 = cfg_pkt_cnt; b0 = cfg_bad_cnt; g = 0;
      while (((cfg_pkt_cnt === p0) && (cfg_bad_cnt === b0)) && (g < 800)) begin
        @(posedge clk); g = g + 1;
      end
      repeat (3) @(posedge clk);
    end
  endtask

  
  
  
  logic [31:0] bad0;
  int          rbp0;

  initial begin
    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    
    
    
    build_wr1(16'h0040, 32'hDEADBEEF);   
    send_pkt(10);
    wait_change();
    $display("  [1] shadow[0]=%08x  cfg_pkt_cnt=%0d  cfg_bad_cnt=%0d",
             u_regs.shadow[0], cfg_pkt_cnt, cfg_bad_cnt);
    check(u_regs.shadow[0] === 32'hDEADBEEF, "1) single write: shadow[0] must be DEADBEEF");
    check(cfg_pkt_cnt === 32'd1,             "1) single write: cfg_pkt_cnt must be 1");
    check(cfg_bad_cnt === 32'd0,             "1) single write: cfg_bad_cnt must be 0");

    
    build_wr1(16'h0002, 32'h0000_0001);
    send_pkt(10);
    wait_change();
    check(config_pending === 1'b1, "1) write 0x008 bit0=1 => config_pending must rise");
    config_safe = 1'b1; repeat (3) @(posedge clk); config_safe = 1'b0;
    wait(!config_pending); repeat (2) @(posedge clk);
    $display("  [1] config_words[31:0]=%08x  config_pending=%0b",
             u_regs.config_words[31:0], config_pending);
    check(u_regs.config_words[31:0] === 32'hDEADBEEF, "1) after commit config_words[31:0] must be DEADBEEF");
    check(config_pending === 1'b0,                    "1) after commit config_pending must clear");

    
    
    
    pkt[0] = 8'h03; pkt[1] = 8'h04; pkt[2] = 8'h00; pkt[3] = 8'h00;
    
    pkt[4] = 8'h41; pkt[5] = 8'h00;
    pkt[6] = 8'h11; pkt[7] = 8'h11; pkt[8] = 8'h11; pkt[9] = 8'h11;
    
    pkt[10] = 8'h42; pkt[11] = 8'h00;
    pkt[12] = 8'h22; pkt[13] = 8'h22; pkt[14] = 8'h22; pkt[15] = 8'h22;
    
    pkt[16] = 8'h43; pkt[17] = 8'h00;
    pkt[18] = 8'h33; pkt[19] = 8'h33; pkt[20] = 8'h33; pkt[21] = 8'h33;
    
    pkt[22] = 8'h44; pkt[23] = 8'h00;
    pkt[24] = 8'h44; pkt[25] = 8'h44; pkt[26] = 8'h44; pkt[27] = 8'h44;
    send_pkt(28);
    wait_change();
    $display("  [2] shadow[1..4]=%08x %08x %08x %08x  cfg_pkt_cnt=%0d",
             u_regs.shadow[1], u_regs.shadow[2], u_regs.shadow[3], u_regs.shadow[4],
             cfg_pkt_cnt);
    check(u_regs.shadow[1] === 32'h11111111, "2) batch write: shadow[1] order/value wrong");
    check(u_regs.shadow[2] === 32'h22222222, "2) batch write: shadow[2] order/value wrong");
    check(u_regs.shadow[3] === 32'h33333333, "2) batch write: shadow[3] order/value wrong");
    check(u_regs.shadow[4] === 32'h44444444, "2) batch write: shadow[4] order/value wrong");
    check(cfg_pkt_cnt === 32'd3,             "2) batch write: cfg_pkt_cnt must be 3");

    
    
    
    build_wr1(16'h0040, 32'h12345678);
    send_pkt(10);
    wait_change();
    build_wr1(16'h0002, 32'h0000_0001);
    send_pkt(10);
    wait_change();
    $display("  [3] after pending-write config_pending=%0b", config_pending);
    check(config_pending === 1'b1, "3) write 0x008 bit0=1 => config_pending must rise");
    config_safe = 1'b1; repeat (3) @(posedge clk); config_safe = 1'b0;
    wait(!config_pending); repeat (2) @(posedge clk);
    $display("  [3] after config_safe config_pending=%0b  config_words[31:0]=%08x",
             config_pending, u_regs.config_words[31:0]);
    check(config_pending === 1'b0,                    "3) config_safe: config_pending must clear");
    check(u_regs.config_words[31:0] === 32'h12345678, "3) after commit config_words[31:0] must be 12345678");

    
    
    
    rbp0 = rb_pulses;
    build_rd1(16'h0000);
    send_pkt(6);
    wait_change();
    $display("  [4] rb_value=%08x  rb_word_index=%08x  pulses=%0d",
             last_rb_val, last_rb_idx, rb_pulses - rbp0);
    check((rb_pulses - rbp0) == 1,      "4) read: exactly one rb_valid pulse expected");
    check(last_rb_val === 32'h31524550, "4) read: ID must be 31524550");
    check(last_rb_idx === 32'd0,        "4) read: rb_word_index must be 0");

    
    
    
    
    bad0 = cfg_bad_cnt;
    pkt[0] = 8'h01; pkt[1] = 8'h01; pkt[2] = 8'h00; pkt[3] = 8'h00;
    pkt[4] = 8'h40; pkt[5] = 8'h00;
    send_pkt(6);
    wait_change();
    $display("  [5a] truncated pkt  -> cfg_bad_cnt %0d -> %0d", bad0, cfg_bad_cnt);
    check(cfg_bad_cnt === bad0 + 32'd1, "5a) truncated pkt must bump cfg_bad_cnt");

    
    bad0 = cfg_bad_cnt;
    pkt[0] = 8'h7F; pkt[1] = 8'h01; pkt[2] = 8'h00; pkt[3] = 8'h00;
    send_pkt(4);
    wait_change();
    $display("  [5b] unknown opcode  -> cfg_bad_cnt %0d -> %0d", bad0, cfg_bad_cnt);
    check(cfg_bad_cnt === bad0 + 32'd1, "5b) unknown opcode must bump cfg_bad_cnt");

    
    bad0 = cfg_bad_cnt;
    pkt[0] = 8'h01; pkt[1] = 8'h01; pkt[2] = 8'h00; pkt[3] = 8'h00;
    for (int i = 4; i < 130; i = i + 1) pkt[i] = 8'hAA;
    send_pkt(130);
    wait_change();
    $display("  [5c] overlong 130B   -> cfg_bad_cnt %0d -> %0d", bad0, cfg_bad_cnt);
    check(cfg_bad_cnt === bad0 + 32'd1, "5c) overlong pkt must bump cfg_bad_cnt");

    
    bad0 = cfg_bad_cnt;
    build_wr1(16'h0200, 32'hCAFEBABE);
    send_pkt(10);
    wait_change();
    $display("  [5d] write RO region -> cfg_bad_cnt %0d -> %0d", bad0, cfg_bad_cnt);
    check(cfg_bad_cnt === bad0 + 32'd1, "5d) AXI bresp!=OKAY must bump cfg_bad_cnt");

    
    rbp0 = rb_pulses;
    build_rd1(16'h0000);
    send_pkt(6);
    wait_change();
    $display("  [5]  after errors, good read: rb_value=%08x pulses=%0d",
             last_rb_val, rb_pulses - rbp0);
    check((rb_pulses - rbp0) == 1,      "5) after errors a good read must still work");
    check(last_rb_val === 32'h31524550, "5) after errors read value must still be ID 31524550");

    
    
    
    // Actual bridge waits through clone before accepting next LUT write.
    build_wr1(16'h0100,32'h0040ffc0);send_pkt(10);wait_change();
    build_wr1(16'h0002,1);send_pkt(10);wait_change();
    check(config_pending,"LUT commit pending");
    @(negedge clk);config_safe=1;repeat(3)@(negedge clk);config_safe=0;
    build_wr1(16'h0101,32'hff800080);send_pkt(10);wait_change();
    check(!config_pending,"Clone completed before queued write completion");
    build_rd1(16'h0100);send_pkt(6);wait_change();
    check(last_rb_val===32'h0040ffc0,"Active LUT0 after clone");
    build_rd1(16'h0101);send_pkt(6);wait_change();
    check(last_rb_val===0,"Shadow write remains invisible before commit");
    build_wr1(16'h0002,1);send_pkt(10);wait_change();
    @(negedge clk);config_safe=1;repeat(3)@(negedge clk);config_safe=0;
    build_rd1(16'h0101);send_pkt(6);wait_change();
    check(last_rb_val===32'hff800080,"Read waits through clone and sees new bank");
    build_rd1(16'h0100);send_pkt(6);wait_change();
    check(last_rb_val===32'h0040ffc0,"Previous LUT retained across clone");
    // Reset during clone, followed immediately by a real bridge request.
    build_wr1(16'h0002,1);send_pkt(10);wait_change();
    @(negedge clk);config_safe=1;repeat(5)@(negedge clk);config_safe=0;rst_n=0;
    repeat(4)@(negedge clk);rst_n=1;
    build_rd1(16'h0100);send_pkt(6);wait_change();
    check(last_rb_val===0,"Reset reinitializes LUT before accepting read");
    check(cfg_bad_cnt===0,"No bridge error on post-reset read");
    if(errors!=0)$fatal(1,"FULL_CFG_BRAM_FAIL errors=%0d",errors);
    $display("FULL_CFG_BRAM_PASS: INIT/CLONE backpressure, queued write/read, reset");
    if (errors == 0)
      $display("PASS cfg_bridge: 5/5 groups passed (single-write/batch-write/pending/readback/error-packets) cfg_pkt_cnt=%0d cfg_bad_cnt=%0d",
               cfg_pkt_cnt, cfg_bad_cnt);
    else
      $display("FAIL cfg_bridge: %0d check(s) failed", errors);
    $finish;
  end

  
  initial begin
    #2_000_000;
    $display("FAIL cfg_bridge: simulation timeout");
    $finish;
  end

endmodule
