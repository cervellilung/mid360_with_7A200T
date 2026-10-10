`timescale 1ns/1ps
// Five-row streaming Census. RAM contents are not reset; border-valid protects them.
// One accepted pixel per clock; synchronous column read followed by window update.
module stereo_census #(parameter integer WIDTH=320, HEIGHT=240)(
 input logic clk,rst,valid,sof,eof,input logic [7:0] gray,
 input logic [31:0] frame_id,input logic [63:0] stamp_us,
 output logic out_valid,out_sof,out_eof,descriptor_valid,
 output logic [23:0] descriptor,output logic [31:0] out_frame_id,
 output logic [63:0] out_stamp_us);
 localparam integer XW=$clog2(WIDTH), YW=$clog2(HEIGHT);
 (* ram_style="block" *) logic [7:0] row0[0:WIDTH-1],row1[0:WIDTH-1],row2[0:WIDTH-1],row3[0:WIDTH-1];
 logic [7:0] column[0:4],win[0:4][0:4];
 logic [XW-1:0] x,px; logic [YW-1:0] y,py;
 logic pv,ps,pe; logic [31:0] fid;logic [63:0] ts;
 wire [XW-1:0] address=sof?'0:x;
 wire [YW-1:0] row=sof?'0:y;
 // Synchronous read-before-write, four independent simple dual-port BRAMs.
 always_ff @(posedge clk) if(valid&&!rst)begin
   column[0]<=row3[address];column[1]<=row2[address];column[2]<=row1[address];column[3]<=row0[address];column[4]<=gray;
   row0[address]<=gray;row1[address]<=row0[address];row2[address]<=row1[address];row3[address]<=row2[address];
 end
 always_ff @(posedge clk)begin
  if(rst)begin x<=0;y<=0;pv<=0;out_valid<=0;out_sof<=0;out_eof<=0;end
  else begin
   pv<=valid;ps<=sof;pe<=eof;out_valid<=pv;out_sof<=pv&&ps;out_eof<=pv&&pe;
   if(valid)begin
    px<=address;py<=row;
    if(sof)begin fid<=frame_id;ts<=stamp_us;end
    if(address==WIDTH-1)begin x<=0;y<=row+1'b1;end else begin x<=address+1'b1;y<=row;end
   end
   if(pv)begin
    out_frame_id<=fid;out_stamp_us<=ts;
    for(integer r=0;r<5;r=r+1)begin
     for(integer c=0;c<4;c=c+1)win[r][c]<=px==0?8'd0:win[r][c+1];
     win[r][4]<=column[r];
    end
   end
   // Computed from the updated window on the next clock, with aligned metadata.
  end
 end
 logic qv,qs,qe;logic [XW-1:0] qx;logic [YW-1:0] qy;
 always_ff @(posedge clk)begin
  if(rst)begin qv<=0;end
  else begin qv<=pv;qs<=ps;qe<=pe;qx<=px;qy<=py;end
 end
 always_comb begin
  integer k;
  k=0;descriptor='0;
  for(integer r=0;r<5;r=r+1)for(integer c=0;c<5;c=c+1)
   if(r!=2||c!=2)begin descriptor[k]=win[r][c]<win[2][2];k=k+1;end
 end
 always_comb begin
  descriptor_valid=qv&&qx>=4&&qy>=4;
 end
endmodule
