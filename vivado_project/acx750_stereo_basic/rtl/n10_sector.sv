`timescale 1ns/1ps
// Fixed-time sector reduction; each published sample has a finite age and validity.
module n10_sector #(parameter integer WINDOW_US=100000,STALE_US=500000)(
 input logic clk,rst,point_valid,point_good,input logic [15:0] angle_cdeg,distance_mm,
 input logic [63:0] now_us,input logic [15:0] forward_cdeg,half_width_cdeg,
 input logic [15:0] min_mm,max_mm,
 output logic valid,updated,output logic [15:0] nearest_mm,
 output logic [31:0] valid_points,output logic [63:0] stamp_us);
 logic [63:0] window_start,last_point;logic [15:0] minimum;logic [31:0] count;
 logic [16:0] delta;logic in_sector;
 always_comb begin
  delta=angle_cdeg>=forward_cdeg?angle_cdeg-forward_cdeg:17'd36000+angle_cdeg-forward_cdeg;
  in_sector=delta<=half_width_cdeg||delta>=17'd36000-half_width_cdeg;
 end
 assign valid=valid_points!=0&&now_us-stamp_us<=STALE_US&&now_us-last_point<=STALE_US;
 always_ff @(posedge clk)begin
  updated<=0;
  if(rst)begin window_start<=now_us;minimum<=16'hffff;count<=0;valid_points<=0;stamp_us<=0;last_point<=0;nearest_mm<=0;end
  else if(now_us-window_start>=WINDOW_US)begin
   nearest_mm<=count!=0?minimum:0;valid_points<=count;stamp_us<=now_us;updated<=1;
   window_start<=now_us;minimum<=16'hffff;count<=0;
   // Boundary sample belongs to the new window, not to both windows.
   if(point_valid&&point_good&&in_sector&&distance_mm>=min_mm&&distance_mm<=max_mm)begin minimum<=distance_mm;count<=1;last_point<=now_us;end
  end else if(point_valid&&point_good&&in_sector&&distance_mm>=min_mm&&distance_mm<=max_mm)begin
   if(distance_mm<minimum)minimum<=distance_mm;
   count<=count+1'b1;last_point<=now_us;
  end
 end
endmodule
