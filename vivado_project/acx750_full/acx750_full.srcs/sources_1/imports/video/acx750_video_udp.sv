// Nonblocking HDMI raster tap. Two 256x16 dual-clock BRAM slots, no frame cache.
// Metadata uses one resettable XPM async FIFO; slots remain immutable until UDP FCS done.
// M3VP timestamp is the FIRST DISPLAY pixel, not sensor exposure time.
`timescale 1ns/1ps
module acx750_video_udp #(
 parameter integer WIDTH=1024, HEIGHT=600, PIXEL_HZ=51_250_000, DECIMATE=1
)(
 input wire pix_clk,eth_clk,capture_rst_n,
 input wire vs,de,input wire [15:0] pixel,
 output logic tx_start,output wire [15:0] tx_len,
 output wire [7:0] tx_data,input wire tx_req,tx_done,
 output logic [31:0] frames_dropped
);
 localparam integer OUTPUT_WIDTH=WIDTH/DECIMATE, OUTPUT_HEIGHT=HEIGHT/DECIMATE;
 localparam integer TOTAL=OUTPUT_WIDTH*OUTPUT_HEIGHT;
 // Constant factor 1 or 2: bit tests, no divider or variable indexing hardware.
 logic [$clog2(WIDTH)-1:0] raster_x;
 logic [$clog2(HEIGHT)-1:0] raster_y;
 wire sample_de=de&&((DECIMATE==1)||(!raster_x[0]&&!raster_y[0]));
 `ifndef SYNTHESIS
 initial if((DECIMATE!=1&&DECIMATE!=2)||WIDTH%DECIMATE||HEIGHT%DECIMATE||TOTAL%256)
   $fatal(1,"Unsupported raster/decimation; output must contain complete 256-pixel chunks");
 `endif
 function automatic [31:0] crcbyte(input [31:0] c,input [7:0] d);
  reg [31:0] v;begin
   v=c^{24'd0,d};
   for(integer k=0;k<8;k=k+1)v=(v>>1)^({32{v[0]}}&32'hedb88320);
   crcbyte=v;
  end
 endfunction
 // A SINGLE registered reset owner is supplied by the SYS domain.
 // Never combine reset outputs from independent clock domains here.
 wire common_reset_n=capture_rst_n;
 wire prst,erst;
 // This is an asynchronous reset request, not ordinary cross-domain data.
 // The vendor reset macro models asynchronous assertion / synchronous release
 // explicitly, including reset-domain CDC recognition and implementation tags.
 xpm_cdc_async_rst #(.DEST_SYNC_FF(2),.INIT_SYNC_FF(1),.RST_ACTIVE_HIGH(0)) u_prst(
  .src_arst(common_reset_n),.dest_clk(pix_clk),.dest_arst(prst));
 xpm_cdc_async_rst #(.DEST_SYNC_FF(2),.INIT_SYNC_FF(1),.RST_ACTIVE_HIGH(0)) u_erst(
  .src_arst(common_reset_n),.dest_clk(eth_clk),.dest_arst(erst));
 logic [1:0] generation,returned;
 wire [1:0] returned_sync;
 wire [1:0] busy=generation^returned_sync;
 logic fifo_write,fifo_read;
 logic [149:0] fifo_in;
 wire [149:0] fifo_out;
 wire fifo_full,fifo_empty,write_busy,read_busy;
 xpm_cdc_array_single #(.DEST_SYNC_FF(2),.WIDTH(2),.SRC_INPUT_REG(0),
  .INIT_SYNC_FF(1),.SIM_ASSERT_CHK(1)) u_return(
  .src_clk(eth_clk),.src_in(returned),.dest_clk(pix_clk),.dest_out(returned_sync));
// XSim 2020.2 XPM SVA falsely reports transitions on tied-low sleep.
 // Match the existing packet FIFO: procedural ownership/flag assertions below
 // replace vendor SVA; do not suppress simulation Errors at the test gate.
 // Only two slots may be outstanding; depth 16 is the XPM minimum. Each bit
 // of returned is an independent ownership toggle, never a binary counter.
 xpm_fifo_async #(.FIFO_MEMORY_TYPE("distributed"),.FIFO_WRITE_DEPTH(16),
  .WRITE_DATA_WIDTH(150),.READ_DATA_WIDTH(150),.READ_MODE("fwft"),
  .FIFO_READ_LATENCY(0),.CDC_SYNC_STAGES(2),.RELATED_CLOCKS(0),
  .USE_ADV_FEATURES("0000"),.SIM_ASSERT_CHK(0),.DOUT_RESET_VALUE("0")) u_metadata(
  .rst(!prst),.wr_clk(pix_clk),.rd_clk(eth_clk),.din(fifo_in),.dout(fifo_out),
  .wr_en(fifo_write),.rd_en(fifo_read),.full(fifo_full),.empty(fifo_empty),
  .wr_rst_busy(write_busy),.rd_rst_busy(read_busy),.sleep(1'b0),
  .injectsbiterr(1'b0),.injectdbiterr(1'b0));
 logic bank,chunk_accept,frame_abort,armed,vs_old;
 logic [19:0] pixel_index;
 logic [31:0] sequence_id,frame_seq,payload_crc;
 logic [63:0] microseconds,frame_stamp;
 logic [25:0] phase;
 logic [5:0] pix_flush;
 wire [26:0] phase_next={1'b0,phase}+27'd1000000;
 wire first_chunk_pixel=(pixel_index[7:0]==0);
 wire slot_free=!busy[bank]&&!fifo_full&&!write_busy;
 wire take=(pix_flush==32)&&armed&&sample_de&&!frame_abort&&(first_chunk_pixel?slot_free:chunk_accept);
 logic selected;
 logic [7:0] read_index;
 wire [15:0] read_value[0:1];
 logic [9:0] byte_index;
 wire advance_pixel=tx_req&&(byte_index>=40)&&byte_index[0];
 wire [7:0] read_address=read_index+{7'd0,advance_pixel};
 generate for(genvar b=0;b<2;b=b+1)begin:slots
  (* ram_style="block" *) logic [15:0] memory[0:255];
  logic [15:0] q;
  // Never reset the BRAM data. Ownership and valid state govern its use.
  always_ff @(posedge pix_clk)if(take&&bank==b)memory[pixel_index[7:0]]<=pixel;
  always_ff @(posedge eth_clk)q<=memory[read_address];
  assign read_value[b]=q;
 end endgenerate
 always_ff @(posedge pix_clk)begin
  if(!prst)begin
   generation<=0;fifo_write<=0;bank<=0;chunk_accept<=0;frame_abort<=1;armed<=0;vs_old<=0;
   pixel_index<=0;sequence_id<=0;frame_seq<=0;payload_crc<=32'hffffffff;
   phase<=0;microseconds<=0;frame_stamp<=0;frames_dropped<=0;pix_flush<=0;raster_x<=0;raster_y<=0;
  end else begin
   if(phase_next>=PIXEL_HZ)begin phase<=phase_next-PIXEL_HZ;microseconds<=microseconds+1'b1;end
   else phase<=phase_next[25:0];
   vs_old<=vs;
   if(vs&&!vs_old)begin raster_x<=0;raster_y<=0;end
   else if(armed&&de)begin
     if(raster_x==WIDTH-1)begin raster_x<=0;raster_y<=raster_y+1'b1;end
     else raster_x<=raster_x+1'b1;
   end
   fifo_write<=0;
   if(pix_flush<32)begin pix_flush<=pix_flush+1'b1;armed<=0;generation<=0;fifo_write<=0;end
   else if(vs&&!vs_old)begin
    pixel_index<=0;frame_abort<=0;armed<=1;chunk_accept<=0;
    frame_seq<=sequence_id;sequence_id<=sequence_id+1'b1;
   end else if(armed&&sample_de)begin
    if(pixel_index==0)frame_stamp<=microseconds;
    if(first_chunk_pixel)begin
     chunk_accept<=slot_free&&!frame_abort;
     if(!slot_free&&!frame_abort)begin frame_abort<=1;frames_dropped<=frames_dropped+1'b1;end
     payload_crc<=crcbyte(crcbyte(32'hffffffff,pixel[7:0]),pixel[15:8]);
    end else if(take)payload_crc<=crcbyte(crcbyte(payload_crc,pixel[7:0]),pixel[15:8]);
    if(take&&pixel_index[7:0]==255)begin
     fifo_in<={bank,!generation[bank],frame_stamp,frame_seq,{pixel_index[19:8],8'd0},
                      ~crcbyte(crcbyte(payload_crc,pixel[7:0]),pixel[15:8])};
     generation[bank]<=!generation[bank];fifo_write<=1;bank<=!bank;
    end
    if(pixel_index==TOTAL-1)armed<=0;
    else pixel_index<=pixel_index+1'b1;
   end
  end
 end
 // Header storage is just 40 bytes, intentionally LUTRAM with asynchronous read.
 (* ram_style="distributed" *) logic [7:0] header[0:39];
 logic [5:0] header_index;
 logic [31:0] header_crc;
 logic [147:0] meta;
 wire [63:0] stamp=meta[147:84];
 wire [31:0] seq=meta[83:52];
 wire [31:0] offset={12'd0,meta[51:32]};
 wire [31:0] pcrc=meta[31:0];
 function automatic [7:0] hbyte(input [5:0] i);
  begin
   case(i)
    0:hbyte=8'h4d;1:hbyte=8'h33;2:hbyte=8'h56;3:hbyte=8'h50;
    4:hbyte=1;5:hbyte=1;6,7:hbyte=0;
    8:hbyte=seq[7:0];9:hbyte=seq[15:8];10:hbyte=seq[23:16];11:hbyte=seq[31:24];
    12:hbyte=stamp[7:0];13:hbyte=stamp[15:8];14:hbyte=stamp[23:16];15:hbyte=stamp[31:24];
    16:hbyte=stamp[39:32];17:hbyte=stamp[47:40];18:hbyte=stamp[55:48];19:hbyte=stamp[63:56];
    20:hbyte=OUTPUT_WIDTH&255;21:hbyte=(OUTPUT_WIDTH>>8)&255;22:hbyte=OUTPUT_HEIGHT&255;23:hbyte=(OUTPUT_HEIGHT>>8)&255;
    24:hbyte=offset[7:0];25:hbyte=offset[15:8];26:hbyte=offset[23:16];27:hbyte=offset[31:24];
    28:hbyte=0;29:hbyte=1;30,31:hbyte=0;
    32:hbyte=pcrc[7:0];33:hbyte=pcrc[15:8];34:hbyte=pcrc[23:16];35:hbyte=pcrc[31:24];
    36:hbyte=~header_crc[7:0];37:hbyte=~header_crc[15:8];38:hbyte=~header_crc[23:16];39:hbyte=~header_crc[31:24];
    default:hbyte=0;
   endcase
  end
 endfunction
 typedef enum logic [2:0]{FLUSH,IDLE,HEADER,START,SEND} state_t;
 state_t state;
 logic [5:0] eth_flush;
 logic selected_generation;
 assign tx_len=16'd552;
 assign tx_data=(byte_index<40)?header[byte_index[5:0]]:
                 (byte_index[0]?read_value[selected][15:8]:read_value[selected][7:0]);
 always_ff @(posedge eth_clk)begin
  if(!erst)begin
   state<=FLUSH;eth_flush<=0;selected<=0;returned<=0;fifo_read<=0;selected_generation<=0;header_index<=0;header_crc<=32'hffffffff;
   byte_index<=0;read_index<=0;tx_start<=0;
  end else begin
   tx_start<=0;
   fifo_read<=0;
   case(state)
    FLUSH:begin
     // Both ownership toggles and the metadata FIFO share common reset.
     returned<=0;
     if(eth_flush<32)eth_flush<=eth_flush+1'b1;
     else if(!read_busy)state<=IDLE;
    end
    IDLE:begin
     byte_index<=0;read_index<=0;
     if(!fifo_empty&&!read_busy)begin
      selected<=fifo_out[149];selected_generation<=fifo_out[148];
      meta<=fifo_out[147:0];fifo_read<=1;
      header_index<=0;header_crc<=32'hffffffff;state<=HEADER;
     end
    end
    HEADER:begin
     header[header_index]<=hbyte(header_index);
     if(header_index<36)header_crc<=crcbyte(header_crc,hbyte(header_index));
     if(header_index==39)state<=START;
     else header_index<=header_index+1'b1;
    end
    START:begin tx_start<=1;state<=SEND;end
    SEND:begin
     if(tx_req)begin
      byte_index<=byte_index+1'b1;
      if(advance_pixel)read_index<=read_index+1'b1;
     end
     if(tx_done)begin returned[selected]<=selected_generation;state<=IDLE;end
    end
   endcase
  end
 end
 // synthesis translate_off
 initial if(TOTAL%256!=0||OUTPUT_WIDTH>1024||OUTPUT_HEIGHT>600)$fatal(1,"M3VP raster requires 256-pixel aligned total");
 always @(posedge eth_clk)if(erst&&tx_req&&state!=SEND)$fatal(1,"Video requested without ownership");
 always @(posedge pix_clk)if(prst&&take&&busy[bank])
  $fatal(1,"Pixel overwrote an outstanding bank");
 always @(posedge pix_clk)if(prst&&fifo_write&&(fifo_full||write_busy))
  $fatal(1,"Metadata FIFO overflow/reset write");
 always @(posedge eth_clk)if(erst&&fifo_read&&(fifo_empty||read_busy))
  $fatal(1,"Metadata FIFO underflow/reset read");
 // synthesis translate_on
endmodule
