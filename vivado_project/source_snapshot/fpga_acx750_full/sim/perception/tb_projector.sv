//============================================================================
// 来源：fpga_ac880/sensor_perception_ar/tests/tb_projector.sv，仅调整路径。
// 说明：从 7020（XC7Z020）工程原样搬入 ACX750 新工程，被测逻辑零改动。
//       `include "perception_types.svh" 由编译器 -i 指向
//       fpga_acx750_full/rtl/perception/ 解析。
//============================================================================
`timescale 1ns/1ps
`include "perception_types.svh"
module tb_projector;
 logic clk=0,rst=1,start=0,cal=0;always #5 clk=~clk;
 logic [4:0] idx;object_t obj;
 logic [287:0] R;logic [95:0] T=0;
 logic [7:0] lut_index;logic signed [15:0] du=0,dv=0;
 logic busy,done;logic [31:0] valid;logic [351:0] x0,x1;logic [319:0] y0,y1;logic [191:0] disp;logic [31:0] nearest;logic [1:0] risk;
 fixed_projector dut(.clk(clk),.rst(rst),.start(start),.count(6'd1),.object_index(idx),.object_data(obj),
  .calibrated(cal),.rotation(R),.translation(T),.fx(32'sd6553600),.fy(32'sd6553600),.cx(32'sd20971520),.cy(32'sd15728640),
  .stereo_gain(32'd17500),.warning_mm(32'd2000),.danger_mm(32'd1000),.lut_index(lut_index),.lut_du(du),.lut_dv(dv),
  .busy(busy),.done(done),.box_valid(valid),.x0(x0),.x1(x1),.y0(y0),.y1(y1),.disparity(disp),.nearest_mm(nearest),.risk(risk));
 task go;begin @(negedge clk);start=1;@(negedge clk);start=0;wait(done);@(negedge clk);end endtask
 initial begin
  R=0;R[32+:32]=-32'sd1073741824;R[160+:32]=-32'sd1073741824;R[192+:32]=32'sd1073741824;
  obj='0;obj.x0=1000;obj.x1=1100;obj.y0=100;obj.y1=200;obj.z0=200;obj.z1=300;obj.d2=1010000;
  #30;rst=0;go();if(valid!==0||nearest!==1004||risk!==1)$fatal(1,"uncalibrated output");
  cal=1;go();
  if(!valid[0]||x0[0+:11]!=380||x1[0+:11]!=390||y0[0+:10]!=210||y1[0+:10]!=221||disp[0+:6]!=17)
    $fatal(1,"projection %d %d %d %d shift%d",x0[0+:11],x1[0+:11],y0[0+:10],y1[0+:10],disp[0+:6]);
  du=-256;dv=256;go();
  if(x0[0+:11]!=379||x1[0+:11]!=389||y0[0+:10]!=211||y1[0+:10]!=222)$fatal(1,"signed LUT correction");
  $display("PASS projector signed floor, calibration gate, stereo, Q8 LUT");$finish;
 end
 initial begin #1000000;$fatal(1,"projector timeout");end
endmodule