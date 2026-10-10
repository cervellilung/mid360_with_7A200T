//============================================================================
// 来源：fpga_ac880/sensor_perception_ar/tests/tb_grid.sv，仅调整路径。
// 说明：从 7020（XC7Z020）工程原样搬入 ACX750 新工程，被测逻辑零改动。
//       本 tb 通过 +input=<文件> / +output=<文件> 收发点云文本。
//       注意：7020 侧由 numpy 参考模型（verify_grid）逐对象比对结果，
//       本工程驱动仅做编译+仿真冒烟（依赖 tb 自身的 PASS），数值比对
//       仍以 7020 驱动为准（详见 sim/README.md）。
//============================================================================
`timescale 1ns/1ps
`include "perception_types.svh"
module tb_grid;
 reg clk=0,rst=1,pv=0;always #5 clk=~clk;
 wire ready,pulse;reg signed [31:0] x,y,z;reg [63:0] ts=0;
 wire [5:0] count;reg [4:0] idx=0;object_t obj;
 wire [63:0] result_us;wire [31:0] accepted,roi,ground,overflow,busy;
 reg signed [31:0] nx=0,ny=0,nz=32'h40000000,dm=0;
 lidar_grid dut(.clk(clk),.rst(rst),.point_valid(pv),.point_ready(ready),.x(x),.y(y),.z(z),.timestamp_ns(ts),.scan_index(32'(ts/100000000)),.now_us(64'd100000),
 .nx_q30(nx),.ny_q30(ny),.nz_q30(nz),.d_mm(dm),.margin_mm(32'd100),.core_points(2'd2),
 .result_pulse(pulse),.object_count(count),.object_index(idx),.object_data(obj),.result_us(result_us),
 .accepted(accepted),.roi_rejected(roi),.ground_rejected(ground),.overflow_points(overflow),.busy_drops(busy));
 integer f,o,n,ret,i;reg [1023:0] input_path,output_path;
 task send_point(input integer a,b,c,input [63:0] t);
 begin @(negedge clk);pv=1;x=a;y=b;z=c;ts=t;do @(posedge clk);while(!ready);@(negedge clk);pv=0;end endtask
 initial begin
  if(!$value$plusargs("input=%s",input_path))input_path="input.txt";
  if(!$value$plusargs("output=%s",output_path))output_path="output.txt";
  f=$fopen(input_path,"r");o=$fopen(output_path,"w");if(!f||!o)$fatal(1,"file open");
  #25;rst=0;
  while(!$feof(f))begin
   ret=$fscanf(f,"%d %d %d\n",x,y,z);
   if(ret==3)send_point(x,y,z,64'd1000000000);
  end
  send_point(0,0,0,64'd1100000000);
  wait(pulse);#1;
  $fdisplay(o,"%d %d %d %d %d",count,accepted,roi-1,ground,overflow);
  for(i=0;i<count;i=i+1)begin @(negedge clk);idx=i;#1;$fdisplay(o,"%h",obj);end
  $fclose(f);$fclose(o);$display("PASS grid");$finish;
 end
 initial begin #100000000;$fatal(1,"grid timeout");end
endmodule