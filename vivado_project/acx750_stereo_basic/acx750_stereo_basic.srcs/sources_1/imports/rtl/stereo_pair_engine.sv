`timescale 1ns/1ps
// System-clock core: complete frame ownership, arrival-time pairing, then raster matching.
// Identity/bypass images must not enable calibrated depth until rectification is verified.
module stereo_pair_engine #(parameter integer WIDTH=320,HEIGHT=240,MAX_SKEW_US=2000)(
 input logic clk,rst,
 input logic l_valid,l_sof,l_eof,input logic [7:0] l_gray,input logic [31:0] l_id,input logic [63:0] l_stamp,
 input logic r_valid,r_sof,r_eof,input logic [7:0] r_gray,input logic [31:0] r_id,input logic [63:0] r_stamp,
 input logic calibration_valid,input logic lut_we,input logic [6:0] lut_address,input logic [15:0] lut_mm,
 input logic [5:0] max_cost,uniqueness,
 output logic depth_valid,depth_good,input logic depth_ready,
 output logic [15:0] depth_mm,output logic [6:0] disparity,
 output logic [$clog2(WIDTH)-1:0] x,output logic [$clog2(HEIGHT)-1:0] y,
 output logic [31:0] frame_id,output logic [63:0] stamp_us,
 output logic [31:0] dropped_left,dropped_right,bad_left,bad_right,rejected_pairs,
 output logic pair_busy,output logic [31:0] pair_right_id);
 localparam integer PIXELS=WIDTH*HEIGHT,AW=$clog2(PIXELS);
 wire lv,ls,le,lg,rv,rs,re,rg;wire [23:0] ld,rd;wire [31:0] li,ri;wire [63:0] lt,rt;
 stereo_census #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) lc(clk,rst,l_valid,l_sof,l_eof,l_gray,l_id,l_stamp,lv,ls,le,lg,ld,li,lt);
 stereo_census #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) rc(clk,rst,r_valid,r_sof,r_eof,r_gray,r_id,r_stamp,rv,rs,re,rg,rd,ri,rt);
 wire lready,rready,lb,rb;wire [31:0] lid,rid;wire [63:0] lst,rstmp;
 logic ltake,rtake,lrelease,rrelease,lrelbank,rrelbank,read_enable;
 logic read_lbank,read_rbank;logic [AW-1:0] address;
 wire [24:0] lread,rread;
 stereo_frame_store #(.PIXELS(PIXELS)) lf(clk,rst,lv,ls,le,{lg,ld},li,lt,lready,lb,lid,lst,ltake,lrelease,lrelbank,read_enable,read_lbank,address,lread,dropped_left,bad_left);
 stereo_frame_store #(.PIXELS(PIXELS)) rf(clk,rst,rv,rs,re,{rg,rd},ri,rt,rready,rb,rid,rstmp,rtake,rrelease,rrelbank,read_enable,read_rbank,address,rread,dropped_right,bad_right);
 logic [3:0] state;logic [31:0] selected_id;logic [63:0] selected_stamp;logic cal_hold;
 logic [5:0] pair_max,pair_unique;
 logic mv;wire mr,ov,og;wire [6:0] od;wire [5:0] oc;wire [$clog2(WIDTH)-1:0] ox;wire [$clog2(HEIGHT)-1:0] oy;
 wire [31:0] oi;wire [63:0] ot;
 logic [63:0] check_left,check_right,skew;
 logic [64:0] delta;
 logic check_lb,check_rb,left_older;
 logic [31:0] check_lid,check_rid;
 wire snapshot_stable=lready&&rready&&lb==check_lb&&rb==check_rb&&lid==check_lid&&rid==check_rid&&lst==check_left&&rstmp==check_right;
 assign pair_busy=state!=0;
 assign read_enable=state==1;assign mv=state==3;
 stereo_match #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) matcher(
  .clk(clk),.rst(rst),.in_valid(mv),.in_ready(mr),.left(lread[23:0]),.right(rread[23:0]),
  .left_valid(lread[24]),.right_valid(rread[24]),.sof(address==0),.frame_id(selected_id),.stamp_us(selected_stamp),
  .max_cost(pair_max),.uniqueness(pair_unique),.out_valid(ov),.out_ready(!depth_valid||depth_ready),
  .matched(og),.disparity(od),.cost(oc),.x(ox),.y(oy),.out_frame_id(oi),.out_stamp_us(ot));
 (* ram_style="distributed" *) logic [15:0] depth_lut[0:127];
 logic [127:0] lut_loaded;
 always_ff @(posedge clk)begin
  if(rst)lut_loaded<=0;
  else if(lut_we&&!pair_busy)lut_loaded[lut_address]<=1;
  if(lut_we&&!pair_busy&&!rst)depth_lut[lut_address]<=lut_mm;
 end
 // One elastic output register, fixed LUT read stage; configuration must be stable for the pair.
 always_ff @(posedge clk)begin
  if(rst)begin depth_valid<=0;depth_good<=0;end
  else if(!depth_valid||depth_ready)begin
   depth_valid<=ov;
   if(ov)begin depth_mm<=og&&cal_hold?depth_lut[od]:16'd0;depth_good<=og&&cal_hold&&(depth_lut[od]!=0);disparity<=od;x<=ox;y<=oy;frame_id<=oi;stamp_us<=ot;end
  end
 end
 always_ff @(posedge clk)begin
  ltake<=0;rtake<=0;lrelease<=0;rrelease<=0;
  if(rst)begin state<=0;address<=0;rejected_pairs<=0;end
  else case(state)
   0:if(lready&&rready)begin
    check_left<=lst;check_right<=rstmp;check_lb<=lb;check_rb<=rb;check_lid<=lid;check_rid<=rid;
    state<=6;
   end
   6:begin delta<={1'b0,check_left}-{1'b0,check_right};state<=7;end
   7:begin skew<=delta[64]?(~delta[63:0]+64'd1):delta[63:0];left_older<=delta[64];state<=8;end
   8:if(!snapshot_stable)state<=0;
   else begin
    if(skew>MAX_SKEW_US)begin
     if(left_older)begin ltake<=1;lrelease<=1;lrelbank<=lb;end
     else begin rtake<=1;rrelease<=1;rrelbank<=rb;end
     rejected_pairs<=rejected_pairs+1'b1;state<=5;
    end else begin
     ltake<=1;rtake<=1;read_lbank<=lb;read_rbank<=rb;
     selected_id<=lid;pair_right_id<=rid;selected_stamp<=lst;cal_hold<=calibration_valid&&(&lut_loaded);
     pair_max<=max_cost;pair_unique<=uniqueness;
     address<=0;state<=1;
    end
   end
   1:state<=2;
   2:state<=3;
   3:if(mr)state<=4;
   4:if(ov&&(!depth_valid||depth_ready))begin
    if(address==PIXELS-1)begin
     lrelease<=1;rrelease<=1;lrelbank<=read_lbank;rrelbank<=read_rbank;state<=5;
    end else begin address<=address+1'b1;state<=1;end
   end
   5:state<=0; // Let the registered take/release pulses reach the slot controllers.
   default:state<=0;
  endcase
 end
endmodule
