// ============================================================================
// 本文件从 fpga_ac880/sensor_perception_ar/rtl/fixed_projector.sv 原样搬入，行为未改。
// 原文件名：fixed_projector.sv
// 原路径：fpga_ac880/sensor_perception_ar/rtl/fixed_projector.sv
// ============================================================================
`timescale 1ns/1ps
`include "perception_types.svh"
module fixed_projector #(parameter BOXES=32)(input logic clk,rst,start,
 input logic [5:0] count,output logic [4:0] object_index,input object_t object_data,
 input logic calibrated,input logic [9*32-1:0] rotation,input logic [3*32-1:0] translation,
 input logic signed [31:0] fx,fy,cx,cy,
 input logic [31:0] stereo_gain,warning_mm,danger_mm,
 output logic [7:0] lut_index,input logic signed [15:0] lut_du,lut_dv,
 output logic busy,done,output logic [BOXES-1:0] box_valid,
 output logic [BOXES*11-1:0] x0,x1,output logic [BOXES*10-1:0] y0,y1,
 output logic [BOXES*6-1:0] disparity,output logic [31:0] nearest_mm,
 output logic [1:0] risk);
 object_t obj;logic [4:0] state;logic [2:0] corner;
 logic signed [31:0] px,py,pz,Xc,Yc,Zc;
 logic signed [64:0] rx,ry,rz;logic signed [63:0] rotation_products[0:8],intrinsic_product;
 logic div_start,div_busy,div_done;logic [63:0] num,quot;
 logic [31:0] den,rem;logic negative;
 logic signed [63:0] coordinate,U,V;
 logic signed [31:0] left,right,top,bottom,ui,vi;
 logic seen;logic sqrt_start,sqrt_busy,sqrt_done;logic [31:0] distance_value;
 logic [31:0] gx,gy;logic [16:0] ax,ay;logic [4:0] lx,ly;
 logic signed [15:0] du[0:3],dv[0:3];logic [1:0] sample;
 logic signed [31:0] du_top,du_bottom,dv_top,dv_bottom,cu,cv;logic signed [33:0] hp[0:7],vp[0:3];
 integer row;
 unsigned_div64 divide(.clk(clk),.rst(rst),.start(div_start),.numerator(num),.denominator(den),.busy(div_busy),.done(div_done),.quotient(quot),.remainder(rem));
 integer_sqrt64 sqrt(.clk(clk),.rst(rst),.start(sqrt_start),.value(obj.d2),.busy(sqrt_busy),.done(sqrt_done),.root(distance_value));
 always_comb begin
  px=corner[2]?obj.x1:obj.x0;py=corner[1]?obj.y1:obj.y0;pz=corner[0]?obj.z1:obj.z0;
  coordinate=negative?-$signed(quot)-(rem!=0):$signed(quot);
  row=gy>>16;
  lx=(gx>>16)>=16?15:(gx>>16);ly=(gy>>16)>=12?11:(gy>>16);
  lut_index=ly*17+lx+(sample[0]?1:0)+(sample[1]?17:0);
 end
 always_ff @(posedge clk) begin
  div_start<=0;sqrt_start<=0;done<=0;
  if(rst)begin state<=0;busy<=0;box_valid<=0;nearest_mm<=0;risk<=0;object_index<=0;end
  else case(state)
   0:if(start)begin
    busy<=1;box_valid<=0;nearest_mm<=0;risk<=0;object_index<=0;
    if(count==0)state<=19;else state<=1;
   end
   1:begin obj<=object_data;corner<=0;seen<=0;left<=639;right<=0;top<=479;bottom<=0;state<=2;end
   2:begin sqrt_start<=1;state<=3;end
   3:if(sqrt_done)begin
    if(object_index==0)begin nearest_mm<=distance_value;risk<=distance_value<=danger_mm?2:distance_value<=warning_mm?1:0;end
    if(distance_value==0)begin disparity[object_index*6+:6]<=0;state<=calibrated?4:18;end
    else begin num<=stereo_gain;den<=distance_value;negative<=0;div_start<=1;state<=20;end
   end
   4:begin
    rotation_products[0]<=$signed(rotation[0+:32])*$signed(px);rotation_products[1]<=$signed(rotation[32+:32])*$signed(py);rotation_products[2]<=$signed(rotation[64+:32])*$signed(pz);
    rotation_products[3]<=$signed(rotation[96+:32])*$signed(px);rotation_products[4]<=$signed(rotation[128+:32])*$signed(py);rotation_products[5]<=$signed(rotation[160+:32])*$signed(pz);
    rotation_products[6]<=$signed(rotation[192+:32])*$signed(px);rotation_products[7]<=$signed(rotation[224+:32])*$signed(py);rotation_products[8]<=$signed(rotation[256+:32])*$signed(pz);state<=26;
   end
   26:begin rx<=rotation_products[0]+rotation_products[1];ry<=rotation_products[3]+rotation_products[4];rz<=rotation_products[6]+rotation_products[7];state<=27;end
   27:begin rx<=rx+rotation_products[2];ry<=ry+rotation_products[5];rz<=rz+rotation_products[8];state<=28;end
   28:begin Xc<=(rx>>>30)+$signed(translation[0+:32]);Yc<=(ry>>>30)+$signed(translation[32+:32]);Zc<=(rz>>>30)+$signed(translation[64+:32]);state<=5;end
   5:if(Zc<=100)state<=16;
    else begin intrinsic_product<=$signed(fx)*$signed(Xc);state<=29;end
   29:begin num<=intrinsic_product<0?-intrinsic_product:intrinsic_product;negative<=intrinsic_product<0;den<=Zc;div_start<=1;state<=6;end
   6:if(div_done)begin U<=coordinate+$signed(cx);intrinsic_product<=$signed(fy)*$signed(Yc);state<=30;end
   30:begin num<=intrinsic_product<0?-intrinsic_product:intrinsic_product;negative<=intrinsic_product<0;den<=Zc;div_start<=1;state<=7;end
   7:if(div_done)begin V<=coordinate+$signed(cy);state<=8;end
   8:begin
    // LUT is fixed at 17x13; negative/outside coordinates clamp to edges.
    num<=U<=0?0:U>=639*65536?16*65536:U*16;den<=U>=639*65536?1:639;div_start<=1;state<=9;
   end
   9:if(div_done)begin gx<=quot>=16*65536?16*65536:quot;
    num<=V<=0?0:V>=479*65536?12*65536:V*12;den<=V>=479*65536?1:479;div_start<=1;state<=10;end
   10:if(div_done)begin gy<=quot>=12*65536?12*65536:quot;state<=11;end
   11:begin ax<=gx-(lx<<16);ay<=gy-(ly<<16);sample<=0;state<=12;end
   12:begin du[sample]<=$signed(lut_du);dv[sample]<=$signed(lut_dv);if(sample==3)state<=21;else sample<=sample+1;end
   // Register each bilinear multiplication/add/rounding stage. The Q8
   // sample bounds guarantee weighted averages stay signed16; 34bit products
   // retain ax/ay=65536 and negative floor semantics exactly.
   21:begin
    hp[0]<=du[0]*$signed({1'b0,17'd65536-ax});hp[1]<=du[1]*$signed({1'b0,ax});
    hp[2]<=du[2]*$signed({1'b0,17'd65536-ax});hp[3]<=du[3]*$signed({1'b0,ax});
    hp[4]<=dv[0]*$signed({1'b0,17'd65536-ax});hp[5]<=dv[1]*$signed({1'b0,ax});
    hp[6]<=dv[2]*$signed({1'b0,17'd65536-ax});hp[7]<=dv[3]*$signed({1'b0,ax});state<=22;
   end
   22:begin du_top<=(hp[0]+hp[1])>>>16;du_bottom<=(hp[2]+hp[3])>>>16;dv_top<=(hp[4]+hp[5])>>>16;dv_bottom<=(hp[6]+hp[7])>>>16;state<=23;end
   23:begin
    vp[0]<=$signed(du_top[15:0])*$signed({1'b0,17'd65536-ay});vp[1]<=$signed(du_bottom[15:0])*$signed({1'b0,ay});
    vp[2]<=$signed(dv_top[15:0])*$signed({1'b0,17'd65536-ay});vp[3]<=$signed(dv_bottom[15:0])*$signed({1'b0,ay});state<=24;
   end
   24:begin cu<=(vp[0]+vp[1])>>>16;cv<=(vp[2]+vp[3])>>>16;state<=25;end
   25:begin ui<=(U+($signed(cu)*64'sd256))>>>16;vi<=(V+($signed(cv)*64'sd256))>>>16;state<=13;end
   13:begin
    if(ui>=0&&ui<640&&vi>=0&&vi<480)begin
     seen<=1;if(ui<left)left<=ui;if(ui>right)right<=ui;if(vi<top)top<=vi;if(vi>bottom)bottom<=vi;
    end
    state<=16;
   end
   16:if(corner==7)state<=17;else begin corner<=corner+1;state<=4;end
   17:begin
    box_valid[object_index]<=seen;
    x0[object_index*11+:11]<=left+80;x1[object_index*11+:11]<=right+80;
    y0[object_index*10+:10]<=top;y1[object_index*10+:10]<=bottom;state<=18;
   end
   18:if(object_index+1>=count)state<=19;else begin object_index<=object_index+1;state<=1;end
   19:begin done<=1;busy<=0;state<=0;end
   20:if(div_done)begin disparity[object_index*6+:6]<=quot>31?31:quot[5:0];state<=calibrated?4:18;end
  endcase
 end
endmodule