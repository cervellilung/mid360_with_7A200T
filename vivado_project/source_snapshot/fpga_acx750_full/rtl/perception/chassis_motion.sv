// ============================================================================
// 本文件从 fpga_ac880/sensor_perception_ar/rtl/chassis_motion.sv 原样搬入，行为未改。
// 原文件名：chassis_motion.sv
// 原路径：fpga_ac880/sensor_perception_ar/rtl/chassis_motion.sv
// ============================================================================
`timescale 1ns/1ps
// vx/vy are Odom v4 raw values: 5000 units per m/s. Arrival dt in PL us.
module chassis_motion(input logic clk,rst,frame_valid,
 input logic signed [15:0] vx_raw,vy_raw,input logic [63:0] now_us,
 output logic valid,updated,output logic [31:0] speed_mm_s,filtered_mm_s,
 output logic [63:0] distance_um,last_us,
 output logic [31:0] rejected,overflow_frames);
 logic sqrt_start,sqrt_busy,sqrt_done;logic [63:0] square;
 logic [31:0] raw_norm;logic [63:0] stamp,dt;
 logic first;logic [3:0] state;
 logic signed [32:0] delta,filter_sum;
 logic [31:0] next_filter,norm_speed,pending_filter;logic [63:0] half_rem;
 logic [31:0] area;logic [14:0] speed_sum;
 logic divide_start,divide_busy,divide_done;logic [63:0] quotient;logic [31:0] remainder;
 unsigned_div64 integrate_divide(.clk(clk),.rst(rst),.start(divide_start),.numerator({32'd0,area}),.denominator(32'd2000),
  .busy(divide_busy),.done(divide_done),.quotient(quotient),.remainder(remainder));
 wire signed [31:0] vx=vx_raw,vy=vy_raw;
 integer_sqrt64 sqrt(.clk(clk),.rst(rst),.start(sqrt_start),.value(square),
  .busy(sqrt_busy),.done(sqrt_done),.root(raw_norm));
 assign valid=!first&&(now_us-last_us<=1000000);
 always_comb begin
  delta=$signed({1'b0,(raw_norm/32'd5)})-$signed({1'b0,filtered_mm_s});
  filter_sum=$signed({1'b0,filtered_mm_s})+(delta>>>3);
  if(first) next_filter=raw_norm/32'd5;
  else next_filter=filter_sum[31:0];
  speed_sum={1'b0,filtered_mm_s[13:0]}+{1'b0,pending_filter[13:0]};
 end
 always_ff @(posedge clk) begin
  sqrt_start<=0;divide_start<=0;updated<=0;
  if(rst) begin state<=0;first<=1;speed_mm_s<=0;filtered_mm_s<=0;
   distance_um<=0;last_us<=0;rejected<=0;overflow_frames<=0;half_rem<=0;dt<=0;area<=0;norm_speed<=0;pending_filter<=0;end
  else begin
   if(frame_valid) begin
    if(state!=0) overflow_frames<=overflow_frames+1;
    else if(!first&&(now_us<=last_us||now_us-last_us>100000)) begin
     rejected<=rejected+1;last_us<=now_us;
    end else begin
     square<=$signed(vx)*$signed(vx)+$signed(vy)*$signed(vy);
     stamp<=now_us;dt<=first?0:now_us-last_us;state<=1;
    end
   end
   if(state==1) begin sqrt_start<=1;state<=2;end
   if(state==2&&sqrt_done)begin norm_speed<=raw_norm/5;state<=3;end
   if(state==3)begin pending_filter<=next_filter;state<=4;end
   // Legal dt <=100000us; speed <=sqrt(2*32768^2)/5=9268mm/s.
   // The exact trapezoid numerator is <2^31; use a registered 15x17 multiply.
   if(state==4)begin area<=speed_sum*dt[16:0]+half_rem[10:0];state<=5;end
   if(state==5)begin divide_start<=1;state<=6;end
   if(state==6&&divide_done)begin
    speed_mm_s<=norm_speed;filtered_mm_s<=pending_filter;
    distance_um<=distance_um+quotient;half_rem<={32'd0,remainder};
    last_us<=stamp;first<=0;updated<=1;state<=0;
   end
  end
 end
endmodule