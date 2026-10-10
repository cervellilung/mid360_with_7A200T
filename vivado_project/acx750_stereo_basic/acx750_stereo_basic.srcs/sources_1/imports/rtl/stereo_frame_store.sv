`timescale 1ns/1ps
// Two complete-frame slots. Ownership: FREE -> WRITING -> READY -> READING -> FREE.
// Serial write/read ports; neither data RAM nor metadata RAM is cleared on reset.
module stereo_frame_store #(parameter integer PIXELS=320*240)(
 input logic clk,rst,valid,sof,eof,input logic [24:0] data,
 input logic [31:0] frame_id,input logic [63:0] stamp_us,
 output logic ready_valid,ready_bank,output logic [31:0] ready_id,
 output logic [63:0] ready_stamp,input logic take,release_slot,release_bank,
 input logic read_enable,read_bank,input logic [$clog2(PIXELS)-1:0] read_address,
 output logic [24:0] read_data,output logic [31:0] dropped,bad_frames);
 localparam integer AW=$clog2(PIXELS);
 // Byte planes favor 9-bit BRAM modes; a 25-bit monolithic RAM wastes width
 // in the 36-bit/1024-deep mode on 7-Series. Valid bits use their own narrow RAM.
 logic [1:0] occupied,complete;logic writing,wb;
 logic [AW:0] count;logic [31:0] ids[0:1];logic [63:0] stamps[0:1];
 logic older_bank1;
 // Metadata is written at SOF and held throughout the frame. Register the
 // ordering before EOF, so READY does not broadcast a 64-bit compare path.
 always_ff @(posedge clk)older_bank1<=stamps[1]<stamps[0];
 wire available=(occupied!=2'b11);
 wire allocation=occupied[0];
 wire active=sof?available:writing;
 wire selected=sof?allocation:wb;
 wire [AW-1:0] wa=sof?'0:count[AW-1:0];
 wire [24:0] rd0,rd1;logic rb_q;
 wire wen=valid&&active&&!rst&&wa<PIXELS;
 // Small simulation memories use correspondingly small legal power-of-two tiles.
 localparam BYTE_TILE=(PIXELS<4096?2**AW:4096),BIT_TILE=(PIXELS<32768?2**AW:32768);
 for(genvar b=0;b<3;b=b+1)begin:bytes
  stereo_tiled_ram #(.DEPTH(PIXELS),.BITS(8),.TILE_DEPTH(BYTE_TILE)) m0(clk,wen&&!selected,wa,data[b*8+:8],read_enable,read_address,rd0[b*8+:8]);
  stereo_tiled_ram #(.DEPTH(PIXELS),.BITS(8),.TILE_DEPTH(BYTE_TILE)) m1(clk,wen&&selected,wa,data[b*8+:8],read_enable,read_address,rd1[b*8+:8]);
 end
 stereo_tiled_ram #(.DEPTH(PIXELS),.BITS(1),.TILE_DEPTH(BIT_TILE)) v0(clk,wen&&!selected,wa,data[24],read_enable,read_address,rd0[24]);
 stereo_tiled_ram #(.DEPTH(PIXELS),.BITS(1),.TILE_DEPTH(BIT_TILE)) v1(clk,wen&&selected,wa,data[24],read_enable,read_address,rd1[24]);
 always_ff @(posedge clk)if(read_enable)rb_q<=read_bank;
 assign read_data=rb_q?rd1:rd0;
 always_comb begin
  ready_valid=|complete;
  // Prefer older timestamp when both slots are complete.
  ready_bank=complete[1]&&(!complete[0]||older_bank1);
  ready_id=ids[ready_bank];ready_stamp=stamps[ready_bank];
 end
 always_ff @(posedge clk)begin
  if(rst)begin occupied<=0;complete<=0;writing<=0;count<=0;dropped<=0;bad_frames<=0;end
  else begin
   if(take&&ready_valid)complete[ready_bank]<=0;
   if(release_slot)begin occupied[release_bank]<=0;complete[release_bank]<=0;end
   if(valid)begin
    if(sof)begin
     if(writing)begin occupied[wb]<=0;bad_frames<=bad_frames+1'b1;end
     writing<=available;wb<=allocation;count<=1;
     if(available)begin occupied[allocation]<=1;ids[allocation]<=frame_id;stamps[allocation]<=stamp_us;end
     else dropped<=dropped+1'b1;
    end else if(writing)begin
     if(count<PIXELS)count<=count+1'b1;
     else begin writing<=0;occupied[wb]<=0;bad_frames<=bad_frames+1'b1;end
    end
    if(eof&&active)begin
     writing<=0;
     if((sof&&PIXELS==1)||(!sof&&count==PIXELS-1))complete[selected]<=1;
     else begin occupied[selected]<=0;bad_frames<=bad_frames+1'b1;end
    end
   end
  end
 end
endmodule
