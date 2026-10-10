// ============================================================================
// 本文件从 fpga_ac880/sensor_perception_ar/rtl/mid360_points.sv 原样搬入，行为未改。
// 原文件名：mid360_points.sv
// 原路径：fpga_ac880/sensor_perception_ar/rtl/mid360_points.sv
// ============================================================================
`timescale 1ns/1ps
// Complete application packet is validated before exposing any point.
module mid360_points(input logic clk,rst,
 input logic [7:0] s_data,input logic s_valid,s_last,output logic s_ready,
 output logic point_valid,input logic point_ready,
 output logic signed [31:0] x,y,z,output logic [63:0] timestamp_ns,output logic [31:0] scan_index,
 output logic [31:0] bad_packets,good_packets,crc_unavailable);
 (* ram_style="block" *) logic [7:0] mem[0:2047];
 logic [7:0] header[0:35];logic [7:0] read_byte;
 logic [11:0] length,wr,pos;logic [15:0] count,index;
 logic [3:0] state;logic [31:0] crc;logic [3:0] step;
 logic [31:0] cx,cy,cz;logic [7:0] dtype;
 function automatic [15:0] le16(input integer a);le16={header[a+1],header[a]};endfunction
 function automatic [31:0] le32(input integer a);le32={header[a+3],header[a+2],header[a+1],header[a]};endfunction
 function automatic [31:0] crc_byte(input [31:0] c,input [7:0] d);
  reg [31:0] v;integer b;begin v=c^d;for(b=0;b<8;b=b+1)v=(v>>1)^(v[0]?32'hedb88320:0);crc_byte=v;end
 endfunction
 logic bucket_start,bucket_busy,bucket_done;logic [63:0] bucket_quotient;logic [31:0] bucket_remainder;
 unsigned_div64 scan_divide(.clk(clk),.rst(rst),.start(bucket_start),.numerator(timestamp_ns),.denominator(32'd100000000),
  .busy(bucket_busy),.done(bucket_done),.quotient(bucket_quotient),.remainder(bucket_remainder));
 assign s_ready=state==0;
 assign point_valid=state==4;
 always_ff @(posedge clk)begin
  if(state==0&&s_valid&&wr<2048)mem[wr[10:0]]<=s_data;
  read_byte<=mem[pos[10:0]];
 end
 always_ff @(posedge clk) begin
  bucket_start<=0;
  if(rst) begin scan_index<=0;state<=0;wr<=0;bad_packets<=0;good_packets<=0;crc_unavailable<=0;x<=0;y<=0;z<=0;timestamp_ns<=0;end
  else case(state)
   0: if(s_valid) begin
    if(wr<36)header[wr]<=s_data;
    if(s_last) begin length<=wr+1;wr<=0;state<=1;end
    else if(wr<2048) wr<=wr+1;
   end
   1: begin
    if(length<36||length>2048||header[0]!=0||le16(1)!=length||le16(3)>10000||
      le16(5)==0||(header[10]!=1&&header[10]!=2)||header[11]>2||
      length!=36+le16(5)*(header[10]==1?14:8)) begin bad_packets<=bad_packets+1;state<=0;end
    else begin crc<=32'hffffffff;pos<=28;count<=le16(5);dtype<=header[10];
      timestamp_ns<={le32(32),le32(28)};state<=5;end
   end
   2: begin
    crc<=crc_byte(crc,read_byte);pos<=pos+1;state<=5;
    if(pos==length-1) begin
     if(le32(24)!=0&&le32(24)!=~crc_byte(crc,read_byte)) begin bad_packets<=bad_packets+1;state<=0;end
     else begin
      good_packets<=good_packets+1;
      if(le32(24)==0)crc_unavailable<=crc_unavailable+1;
      index<=0;pos<=36;step<=0;cx<=0;cy<=0;cz<=0;state<=7;
     end
    end
   end
   3: begin
    state<=6;
    if(dtype==1) begin
     if(step<4)cx[step*8+:8]<=read_byte;
     else if(step<8)cy[(step-4)*8+:8]<=read_byte;
     else if(step<12)cz[(step-8)*8+:8]<=read_byte;
     if(step==13) begin x<=$signed(cx);y<=$signed(cy);z<=$signed(cz);state<=4;end
    end else begin
     if(step<2)cx[step*8+:8]<=read_byte;
     else if(step<4)cy[(step-2)*8+:8]<=read_byte;
     else if(step<6)cz[(step-4)*8+:8]<=read_byte;
     if(step==7)begin x<=$signed(cx[15:0])*10;y<=$signed(cy[15:0])*10;z<=$signed(cz[15:0])*10;state<=4;end
    end
    pos<=pos+1;step<=step+1;
   end
   4: if(point_ready) begin
    if(index==count-1)state<=0;
    else begin index<=index+1;step<=0;cx<=0;cy<=0;cz<=0;state<=6;end
   end
   5:state<=2;
   6:state<=3;
   7:begin bucket_start<=1;state<=8;end
   8:if(bucket_done)begin scan_index<=bucket_quotient[31:0];state<=6;end
   default:state<=0;
  endcase
 end
endmodule