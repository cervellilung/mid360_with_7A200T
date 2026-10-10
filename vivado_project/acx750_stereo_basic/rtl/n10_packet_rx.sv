`timescale 1ns/1ps
// N10_V1.0 manufacturer format: A5 5A, length=58, BE angles/distances,
// 16 three-byte samples, SUM8 of bytes 0..56. Not N10P / not polynomial CRC8.
// Protocol reference is recorded in docs; electrical/firmware identity remains a board gate.
module n10_packet_rx #(parameter integer BYTE_TIMEOUT_US=2000)(
 input logic clk,rst,byte_valid,input logic [7:0] byte_data,
 input logic [63:0] now_us,output logic point_valid,input logic point_ready,
 output logic [15:0] angle_cdeg,distance_mm,output logic [7:0] intensity,
 output logic point_good,point_last,output logic [63:0] packet_stamp,
 output logic [31:0] packets,bad_packets,busy_drops);
 logic [5:0] index;logic [7:0] sum,hi;
 logic [15:0] start_angle,end_angle;
 logic [15:0] dist[0:15];logic [7:0] inten[0:15];
 logic [3:0] sample_index,emit_index;
 logic [1:0] sample_byte,state;
 logic [15:0] span,step,rem_step,rem_acc,current_angle;
 logic [63:0] last_byte;
 wire [16:0] next_angle={1'b0,current_angle}+{1'b0,step}+((rem_acc+rem_step)>=15?17'd1:17'd0);
 wire [16:0] angular_span=end_angle>=start_angle?{1'b0,end_angle}-{1'b0,start_angle}:17'd36000+end_angle-start_angle;
 assign point_valid=state==3;
 assign distance_mm=dist[emit_index];assign intensity=inten[emit_index];
 assign angle_cdeg=current_angle;assign point_good=distance_mm!=0&&distance_mm!=16'hffff;
 assign point_last=emit_index==15;
 always_ff @(posedge clk)begin
  if(rst)begin index<=0;state<=0;packets<=0;bad_packets<=0;busy_drops<=0;end
  else begin
   if(state==0&&index!=0&&now_us-last_byte>BYTE_TIMEOUT_US)begin index<=0;bad_packets<=bad_packets+1'b1;end
   if(byte_valid)begin
    last_byte<=now_us;
    if(state!=0)busy_drops<=busy_drops+1'b1;
    else if(index==0)begin
     if(byte_data==8'ha5)begin index<=1;sum<=8'ha5;packet_stamp<=now_us;end
    end else if(index==1)begin
     if(byte_data==8'h5a)begin index<=2;sum<=sum+byte_data;end
     else if(byte_data==8'ha5)begin sum<=8'ha5;packet_stamp<=now_us;end
     else index<=0;
    end else if(index==2&&byte_data!=58)begin index<=0;bad_packets<=bad_packets+1'b1;end
    else begin
     if(index==57)begin
      index<=0;
      if(byte_data==sum&&start_angle<36000&&end_angle<36000)begin state<=1;packets<=packets+1'b1;end
      else bad_packets<=bad_packets+1'b1;
     end else begin
      sum<=sum+byte_data;index<=index+1'b1;
      if(index==5)start_angle[15:8]<=byte_data;
      if(index==6)begin start_angle[7:0]<=byte_data;sample_index<=0;sample_byte<=0;end
      if(index>=7&&index<=54)begin
       case(sample_byte)
        0:begin hi<=byte_data;sample_byte<=1;end
        1:begin dist[sample_index]<={hi,byte_data};sample_byte<=2;end
        2:begin inten[sample_index]<=byte_data;sample_byte<=0;sample_index<=sample_index+1'b1;end
       endcase
      end
      if(index==55)end_angle[15:8]<=byte_data;
      if(index==56)end_angle[7:0]<=byte_data;
     end
    end
   end
   // Constant /15 and %15 at packet rate only, separated from angle accumulation.
   if(state==1)begin span<=angular_span[15:0];state<=2;end
   if(state==2)begin step<=span/15;rem_step<=span%15;rem_acc<=0;current_angle<=start_angle;emit_index<=0;state<=3;end
   if(state==3&&point_ready)begin
    if(emit_index==15)state<=0;
    else begin
     emit_index<=emit_index+1'b1;
     current_angle<=next_angle>=36000?next_angle-36000:next_angle[15:0];
     rem_acc<=rem_acc+rem_step>=15?rem_acc+rem_step-15:rem_acc+rem_step;
    end
   end
  end
 end
endmodule
