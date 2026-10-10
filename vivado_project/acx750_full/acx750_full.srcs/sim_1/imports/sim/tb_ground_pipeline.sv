`timescale 1ns/1ps
`include "perception_types.svh"
module tb_ground_pipeline;
reg clk=0,rst=1,pv=0;always #5 clk=~clk;
reg signed [31:0] nx=0,ny=0,nz=0,d=0,margin=0,x=0,y=0,z=0;
wire ready;wire [31:0] accepted,ground,overflow;object_t obj;
reg [352:0] vec[0:511];integer i,ag=0,gg=0;
reg signed [95:0] expected;
reg signed [63:0] expected_distance;
reg reject;reg [31:0] scan_index=0;wire analysis_busy;
lidar_grid dut(.clk(clk),.rst(rst),.point_valid(pv),.point_ready(ready),.x(x),.y(y),.z(z),
 .timestamp_ns(64'd0),.now_us(64'd0),.scan_index(scan_index),.nx_q30(nx),.ny_q30(ny),.nz_q30(nz),.d_mm(d),.margin_mm(margin),.core_points(2'd2),
 .result_pulse(),.analysis_busy(analysis_busy),.object_count(),.object_index(5'd0),.object_data(obj),.result_us(),
 .accepted(accepted),.roi_rejected(),.ground_rejected(ground),.overflow_points(overflow),.busy_drops(),.grid_rd_addr(12'd0),.grid_rd_data());
initial begin
 $readmemh("ground_vectors.mem",vec);#25;rst=0;wait(ready);
 for(i=0;i<512;i=i+1)begin
  @(negedge clk);{nx,ny,nz,d,margin,x,y,z,expected,reject}=vec[i];pv=1;
  do @(posedge clk);while(!ready);
  @(negedge clk);pv=0;
  wait(dut.cs==1);#1;
  if(dut.plane_sum!==expected)$fatal(1,"PLANE vector=%0d got=%h expected=%h",i,dut.plane_sum,expected);
  wait(ready);#1;if(reject)gg=gg+1;else ag=ag+1;
  expected_distance=$signed(x)*$signed(x)+$signed(y)*$signed(y);
  if(!reject&&dut.pd2!==expected_distance)$fatal(1,"DISTANCE vector=%0d",i);
  if(accepted!==ag||ground!==gg)$fatal(1,"GROUND vector=%0d",i);
 end
 // Same cell repeated, count saturation, and 40000 point cap on this scan.
 nx=0;ny=0;nz=32'h40000000;d=0;margin=100;x=1000;y=0;z=300;
 for(i=512;i<40002;i=i+1)begin
  @(negedge clk);pv=1;do @(posedge clk);while(!ready);
  @(negedge clk);pv=0;wait(ready);#1;
 end
 if(accepted!==ag+39488||overflow!==2)$fatal(1,"OVERFLOW accepted=%0d overflow=%0d",accepted,overflow);
 if(dut.cap_cell.count!==255)$fatal(1,"CELL saturation");
 @(negedge clk);scan_index=1;x=1100;y=-200;z=400;pv=1;
 do @(posedge clk);while(!ready);@(negedge clk);pv=0;wait(ready);#1;
 if(accepted!==ag+39489||overflow!==2||dut.bank!==1||dut.input_count!==1)$fatal(1,"SCAN rollover");
 if(dut.cap_cell.count!==0||dut.new_cell.count!==1)$fatal(1,"SCAN bank contamination");
 wait(!analysis_busy);
 $display("GROUND_PIPELINE_PASS: 512 exact signed vectors, threshold boundaries, same-cell saturation, 40000 cap, scan rollover");$finish;
end
initial begin #10000000;$fatal(1,"GROUND TIMEOUT");end
endmodule
