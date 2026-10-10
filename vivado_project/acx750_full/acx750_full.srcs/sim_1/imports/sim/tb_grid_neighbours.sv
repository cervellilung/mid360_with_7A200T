`timescale 1ns/1ps
`include "perception_types.svh"
module tb_grid_neighbours;
reg clk=0,rst=1,pv=0;always #5 clk=~clk;
reg signed [31:0] x=0,y=0,z=300;
reg [31:0] scan_index=0;reg [4:0] obj_index=0;
wire ready,busy,result_pulse;wire [5:0] count;object_t obj;
integer i,k,columns_checked=0;
lidar_grid dut(.clk(clk),.rst(rst),.point_valid(pv),.point_ready(ready),.x(x),.y(y),.z(z),
 .timestamp_ns(64'd0),.now_us(64'd0),.scan_index(scan_index),.nx_q30(32'd0),.ny_q30(32'd0),.nz_q30(32'h40000000),.d_mm(32'd0),.margin_mm(32'd100),.core_points(2'd2),
 .result_pulse(result_pulse),.analysis_busy(busy),.object_count(count),.object_index(obj_index),.object_data(obj),.result_us(),
 .accepted(),.roi_rejected(),.ground_rejected(),.overflow_points(),.busy_drops(),.grid_rd_addr(12'd0),.grid_rd_data());
task put_cell(input integer addr,input integer repeats);
 integer j;
 begin
  for(j=0;j<repeats;j=j+1)begin
   @(negedge clk);x=550+(addr%55)*100;y=-2950+(addr/55)*100;pv=1;
   do @(posedge clk);while(!ready);
   @(negedge clk);pv=0;wait(ready);
  end
 end
endtask
task finish_scan(input integer next_scan,input integer expected_count);
 begin
  scan_index=next_scan;put_cell(1000,1);
  wait(result_pulse);#1;
  if(count!==expected_count)$fatal(1,"OBJECTS scan=%0d got=%0d expected=%0d",next_scan-1,count,expected_count);
 end
endtask
always @(negedge clk)if(!rst&&dut.as==5)begin
 if(dut.current_col!==dut.current%55)$fatal(1,"COLUMN addr=%0d col=%0d",dut.current,dut.current_col);
 columns_checked=columns_checked+1;
end
initial begin
 #25;rst=0;wait(ready);
 // Four separate valid components touching each corner and all boundary types.
 put_cell(0,4);put_cell(1,4);put_cell(54,4);put_cell(109,4);
 put_cell(3190,4);put_cell(3245,4);put_cell(3298,4);put_cell(3299,4);
 finish_scan(1,4);
 for(k=0;k<4;k=k+1)begin obj_index=k;#1;if(obj.cells!==2||obj.points!==8)$fatal(1,"BOUNDARY component %0d",k);end
 wait(!busy);
 // Adjacent linear addresses on opposite row edges MUST remain separate.
 put_cell(54,4);put_cell(55,4);finish_scan(2,0);wait(!busy);
 // Fill the entire bounded queue: every column/row and all 3300 cells.
 for(i=0;i<3300;i=i+1)put_cell(i,8);
 finish_scan(3,1);obj_index=0;#1;
 // Cell 1000 also contained the one point that opened scan 2.
 if(obj.cells!==3300||obj.points!==26401)$fatal(1,"FULL region cells=%0d points=%0d",obj.cells,obj.points);
 // Scan 1 includes the single-point opener, visited in the sparse pass.
 if(columns_checked!==3311)$fatal(1,"VISITS got=%0d",columns_checked);
 wait(!busy);
 $display("GRID_NEIGHBOURS_PASS: corners, row-wrap isolation, 3300 queue entries and exact columns");$finish;
end
initial begin #10000000;$fatal(1,"NEIGHBOURS TIMEOUT");end
endmodule
