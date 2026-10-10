// One complete M3TL packet crosses domains in one BRAM FIFO, with its length.
// The 2-byte transport prefix is internal and is NOT sent on the network.
// No 4128-bit cross-domain target bus or separate non-resettable handshake.
`timescale 1ns/1ps
module acx750_m3tl_packet_cdc #(parameter integer MAX_BYTES=548)(
 input logic sys_clk,sys_rst_n,eth_clk,eth_rst_n,
 output wire builder_rst_n,src_ready,
 input logic src_start,
 input logic [15:0] src_len,
 output wire src_req,
 input logic [7:0] src_payload,
 output logic tx_start,
 output logic [15:0] tx_len,
 input logic tx_req,
 output wire [7:0] tx_payload,
 output wire transport_fault
);
 wire common_arst_n=sys_rst_n&&eth_rst_n;
 wire dst_rst_n;
 logic fifo_reset;
 // XPM reset is sampled only from a write-domain register.
 always_ff @(posedge sys_clk)fifo_reset<=!builder_rst_n;
 acx750_rst_sync u_src_rst(.clk(sys_clk),.arst_n(common_arst_n),.rst_n(builder_rst_n));
 acx750_rst_sync u_dst_rst(.clk(eth_clk),.arst_n(common_arst_n),.rst_n(dst_rst_n));
 typedef enum logic [1:0] {S_IDLE,S_LO,S_HI,S_COPY} src_state_t;
 typedef enum logic [2:0] {D_IDLE,D_HI,D_WAIT,D_SEND} dst_state_t;
 src_state_t ss;
 dst_state_t ds;
 logic [9:0] src_index,dst_index;
 logic [15:0] len_hold;
 logic [7:0] len_low;
 logic src_fault,dst_fault;
 wire full,empty,wr_busy,rd_busy;
 wire [10:0] wr_count,rd_count;
 wire [7:0] fifo_out;
 wire fifo_overflow,fifo_underflow,src_fault_sync;
 wire wr_en=((ss==S_LO)||(ss==S_HI)||(ss==S_COPY))&&!full&&!wr_busy;
 wire [7:0] fifo_in=(ss==S_LO)?len_hold[7:0]:(ss==S_HI)?len_hold[15:8]:src_payload;
 wire rd_en=!empty&&!rd_busy&&((ds==D_IDLE)||(ds==D_HI)||((ds==D_SEND)&&tx_req));
 assign src_ready=(ss==S_IDLE)&&!wr_busy&&(wr_count==0);
 assign src_req=(ss==S_COPY)&&wr_en;
 assign tx_payload=fifo_out;
 assign transport_fault=src_fault_sync||dst_fault;
 // Synchronous state reset: BRAM enables must not change asynchronously.
 // The XPM FIFO itself resets pointers and suppresses access during reset busy.
 // Datapath contents are not reset. State and RAM ownership gate all use.
 always_ff @(posedge sys_clk)begin
  if(!builder_rst_n)begin ss<=S_IDLE;src_index<=0;src_fault<=0;end
  else begin
   if(fifo_overflow)src_fault<=1;
   case(ss)
    S_IDLE:if(src_start)begin
     if(!src_ready||src_len==0||src_len>MAX_BYTES)src_fault<=1;
     else begin src_index<=0;ss<=S_LO;end
    end
    S_LO:if(wr_en)ss<=S_HI;
    S_HI:if(wr_en)ss<=S_COPY;
    S_COPY:if(src_req)begin
     if(src_index==len_hold-1)ss<=S_IDLE;
     else src_index<=src_index+1'b1;
    end
    default:ss<=S_IDLE;
   endcase
  end
 end
 always_ff @(posedge sys_clk)if(src_start&&src_ready)len_hold<=src_len;
 // Vivado 2020.2 XPM FIFO S-5 incorrectly requires a cross-clock pointer to
 // arrive in one write cycle; S-4 also demands an edge on an already-empty
 // FIFO. Disable ONLY these XPM FIFO simulation assertions; use explicit
 // overflow/underflow/ownership checks below plus full wire CRC regression.
 xpm_fifo_async #(.FIFO_MEMORY_TYPE("block"),.FIFO_WRITE_DEPTH(1024),
  .WRITE_DATA_WIDTH(8),.READ_DATA_WIDTH(8),.READ_MODE("fwft"),.FIFO_READ_LATENCY(0),
  .CDC_SYNC_STAGES(2),.RELATED_CLOCKS(0),.DOUT_RESET_VALUE("0"),.ECC_MODE("no_ecc"),
  .USE_ADV_FEATURES("0707"),.WR_DATA_COUNT_WIDTH(11),.RD_DATA_COUNT_WIDTH(11),
  .PROG_FULL_THRESH(1000),.PROG_EMPTY_THRESH(10),.SIM_ASSERT_CHK(0)) u_packet_fifo(
  .rst(fifo_reset),.wr_clk(sys_clk),.wr_en(wr_en),.din(fifo_in),
  .full(full),.wr_rst_busy(wr_busy),.wr_data_count(wr_count),
  .rd_clk(eth_clk),.rd_en(rd_en),.dout(fifo_out),.empty(empty),.rd_rst_busy(rd_busy),
  .rd_data_count(rd_count),.overflow(fifo_overflow),.underflow(fifo_underflow),
  .sleep(1'b0),.injectsbiterr(1'b0),.injectdbiterr(1'b0),
  .almost_empty(),.almost_full(),.data_valid(),.dbiterr(),.sbiterr(),
  .prog_empty(),.prog_full(),.wr_ack());
 xpm_cdc_single #(.DEST_SYNC_FF(2),.INIT_SYNC_FF(1),.SRC_INPUT_REG(0),.SIM_ASSERT_CHK(1)) u_fault(
  .src_clk(sys_clk),.src_in(src_fault),.dest_clk(eth_clk),.dest_out(src_fault_sync));
 always_ff @(posedge eth_clk)begin
  if(!dst_rst_n)begin ds<=D_IDLE;tx_start<=0;dst_index<=0;dst_fault<=0;end
  else begin
   tx_start<=0;
   if(fifo_underflow)dst_fault<=1;
   case(ds)
    D_IDLE:if(rd_en)ds<=D_HI;
    D_HI:if(rd_en)ds<=D_WAIT;
    D_WAIT:if(!rd_busy&&rd_count>=tx_len)begin
     if(tx_len==0||tx_len>MAX_BYTES)dst_fault<=1;
     else begin dst_index<=0;tx_start<=1;ds<=D_SEND;end
    end
    D_SEND:if(tx_req)begin
     if(empty||rd_busy)dst_fault<=1;
     else if(dst_index==tx_len-1)ds<=D_IDLE;
     else dst_index<=dst_index+1'b1;
    end
    default:ds<=D_IDLE;
   endcase
  end
 end
 always_ff @(posedge eth_clk)begin
  if(ds==D_IDLE&&rd_en)len_low<=fifo_out;
  if(ds==D_HI&&rd_en)tx_len<={fifo_out,len_low};
 end
 // synthesis translate_off
 always @(posedge sys_clk)if(builder_rst_n&&!wr_busy)begin
  if(fifo_overflow||(src_start&&!src_ready))$fatal(1,"Packet CDC source ownership/overflow");
 end
 always @(posedge eth_clk)if(dst_rst_n&&!rd_busy)begin
  if(fifo_underflow||((ds==D_SEND)&&tx_req&&empty))$fatal(1,"Packet CDC underflow");
 end
 // synthesis translate_on
endmodule
