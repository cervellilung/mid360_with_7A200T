`timescale 1ns/1ps
// OV5640 RGB565, high byte first, HREF active high, VSYNC blank active high.
// Tokens: 01 START, 00 PIXEL, 10 END with bit0 = complete source frame.
// DVP cannot be stalled. Lost tokens invalidate the whole frame; END is retried.
module stereo_dvp_tokens #(parameter integer WIDTH=640,HEIGHT=480,SKIP_FRAMES=10)(
 input logic pclk,rst,enable,vsync,href,input logic [7:0] data,
 output logic valid,input logic ready,output logic [17:0] token,
 output logic overflow_seen);
 localparam BW=$clog2(WIDTH*2+2),YW=$clog2(HEIGHT+2),SW=(SKIP_FRAMES<2?1:$clog2(SKIP_FRAMES+1));
 logic vs_q,hs_q,active,phase,fault;
 logic [7:0] hi;
 logic [BW-1:0] bytes;
 logic [YW-1:0] lines;
 logic [SW-1:0] skipped;
 wire lost=valid&&token[17:16]!=2'b10&&!ready;
 wire end_blocked=valid&&token[17:16]==2'b10&&!ready;
 always_ff @(posedge pclk)begin
  vs_q<=vsync;hs_q<=href;
  if(rst)begin
   vs_q<=1;hs_q<=0;active<=0;phase<=0;fault<=0;valid<=0;
   bytes<=0;lines<=0;skipped<=0;overflow_seen<=0;
  end else begin
   if(lost)begin fault<=1;overflow_seen<=1;end
   if(!end_blocked)begin
    valid<=0;
    if(vsync&&!vs_q)begin
     if(enable&&skipped<SKIP_FRAMES)skipped<=skipped+1'b1;
     if(active)begin
      token<={2'b10,15'd0,(!fault&&!lost&&lines==HEIGHT&&!hs_q&&!phase)};
      valid<=1;
     end
     active<=0;phase<=0;bytes<=0;
    end else if(!vsync&&vs_q)begin
     if(enable&&skipped>=SKIP_FRAMES)begin
      token<={2'b01,16'd0};valid<=1;active<=1;fault<=0;lines<=0;bytes<=0;phase<=0;
     end
    end else if(active&&!vsync)begin
     if(href)begin
      if(bytes<WIDTH*2+1)bytes<=bytes+1'b1;
      else fault<=1;
      if(lines>=HEIGHT)fault<=1;
      if(!phase)begin hi<=data;phase<=1;end
      else begin
       token<={2'b00,hi,data};valid<=1;phase<=0;
       if(bytes>=WIDTH*2)fault<=1;
      end
     end else if(hs_q)begin
      if(bytes!=WIDTH*2||phase)fault<=1;
      if(lines<HEIGHT+1)lines<=lines+1'b1;
      bytes<=0;phase<=0;
     end
    end
   end else begin
    // Retain END until it crosses; ignore subsequent DVP frames while blocked.
    active<=0;phase<=0;
   end
  end
 end
endmodule
