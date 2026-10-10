`timescale 1ns/1ps
`include "perception_types.svh"
module tb_projector_viewport;
 reg clk=0,rst=1,start=0; always #5 clk=~clk;
 object_t obj; reg [287:0] rotation=0;
 wire [4:0] oi0,oi1; wire busy0,busy1,done0,done1; wire [31:0] bv0,bv1;
 wire [351:0] x00,x10,x01,x11; wire [319:0] y00,y10,y01,y11;
 wire [7:0] li0,li1; wire [191:0] d0,d1; wire [31:0] n0,n1; wire [1:0] risk0,risk1;
 fixed_projector #(.VIEW_WIDTH(800),.VIEW_HEIGHT(480),.VIEW_X_OFFSET(0)) current_view(
 .clk(clk),.rst(rst),.start(start),.count(6'd1),.object_index(oi0),.object_data(obj),.calibrated(1'b1),
 .rotation(rotation),.translation(96'd0),.fx(32'sd6553600),.fy(32'sd6553600),.cx(32'sd0),.cy(32'sd0),
 .stereo_gain(32'd12000),.warning_mm(32'd2000),.danger_mm(32'd500),.lut_index(li0),.lut_du(16'sd0),.lut_dv(16'sd0),
 .busy(busy0),.done(done0),.box_valid(bv0),.x0(x00),.x1(x10),.y0(y00),.y1(y10),.disparity(d0),.nearest_mm(n0),.risk(risk0));
 fixed_projector #(.VIEW_WIDTH(640),.VIEW_HEIGHT(480),.VIEW_X_OFFSET(80)) legacy_view(
 .clk(clk),.rst(rst),.start(start),.count(6'd1),.object_index(oi1),.object_data(obj),.calibrated(1'b1),
 .rotation(rotation),.translation(96'd0),.fx(32'sd6553600),.fy(32'sd6553600),.cx(32'sd0),.cy(32'sd0),
 .stereo_gain(32'd12000),.warning_mm(32'd2000),.danger_mm(32'd500),.lut_index(li1),.lut_du(16'sd0),.lut_dv(16'sd0),
 .busy(busy1),.done(done1),.box_valid(bv1),.x0(x01),.x1(x11),.y0(y01),.y1(y11),.disparity(d1),.nearest_mm(n1),.risk(risk1));
 task run_point(input integer xx,input integer yy,input integer expect_x,input bit legacy_valid);
 integer cycles; bit seen0,seen1;
 begin
  obj='0;obj.x0=xx;obj.x1=xx;obj.y0=yy;obj.y1=yy;obj.z0=1000;obj.z1=1000;obj.d2=3000000;
  @(negedge clk);start=1;@(negedge clk);start=0;cycles=0;seen0=0;seen1=0;
  while(!(seen0&&seen1)&&cycles<20000)begin @(posedge clk);#1;seen0=seen0|done0;seen1=seen1|done1;cycles=cycles+1;end
  if(!(seen0&&seen1))$fatal(1,"projector timeout");
  if(!bv0[0]||x00[10:0]!==expect_x||x10[10:0]!==expect_x||y00[9:0]!==yy/10)$fatal(1,"800 viewport mismatch");
  if(bv1[0]!==legacy_valid)$fatal(1,"legacy valid mismatch");
  if(legacy_valid&&(x01[10:0]!==expect_x+80||x11[10:0]!==expect_x+80))$fatal(1,"legacy offset mismatch");
  $display("VIEW_POINT x=%0d y=%0d cycles=%0d current=%0d legacy_valid=%0d",xx,yy,cycles,x00[10:0],bv1[0]);
  repeat(3)@(negedge clk);
 end endtask
 initial begin
  obj='0;rotation[0+:32]=32'h40000000;rotation[128+:32]=32'h40000000;rotation[256+:32]=32'h40000000;
  repeat(4)@(negedge clk);rst=0;
  run_point(1000,1000,100,1);run_point(7000,1000,700,0);run_point(7990,4790,799,0);
  $display("PASS tb_projector_viewport: 800+0 and explicit 640+80 coordinate and boundary checks");$finish;
 end
endmodule
