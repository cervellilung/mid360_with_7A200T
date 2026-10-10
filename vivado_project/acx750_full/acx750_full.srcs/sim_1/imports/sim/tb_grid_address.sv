`timescale 1ns/1ps
`include "perception_types.svh"
module tb_grid_address;
  reg clk=0,rst=1,pv=0;always #5 clk=~clk;
  reg signed [31:0] x=0,y=0,z=300;
  wire ready;wire [31:0] accepted,roi;
  object_t obj;
  lidar_grid dut(.clk(clk),.rst(rst),.point_valid(pv),.point_ready(ready),
    .x(x),.y(y),.z(z),.timestamp_ns(64'd0),.now_us(64'd0),.scan_index(32'd0),
    .nx_q30(32'sd0),.ny_q30(32'sd0),.nz_q30(32'h40000000),
    .d_mm(32'sd0),.margin_mm(32'sd100),.core_points(2'd2),
    .result_pulse(),.analysis_busy(),.object_count(),.object_index(5'd0),
    .object_data(obj),.result_us(),.accepted(accepted),.roi_rejected(roi),
    .ground_rejected(),.overflow_points(),.busy_drops(),
    .grid_rd_addr(12'd0),.grid_rd_data());
  task point(input integer a,b,expected);
    begin
      @(negedge clk);x=a;y=b;pv=1;
      do @(posedge clk);while(!ready);
      @(negedge clk);pv=0;
      if(expected>=0)begin
        wait(dut.cs==2);#1;
        if(dut.cap_addr!==12'(expected))$fatal(1,"ADDRESS x=%0d y=%0d got=%0d expected=%0d",a,b,dut.cap_addr,expected);
        if(dut.pd2!==64'(a*a+b*b))$fatal(1,"DISTANCE x=%0d y=%0d got=%0d expected=%0d",a,b,dut.pd2,a*a+b*b);
      end
      wait(ready);#1;
    end
  endtask
  integer row,col;
  initial begin
    #25;rst=0;wait(ready);
    for(row=0;row<60;row=row+1)
      for(col=0;col<55;col=col+1)begin
        point(500+col*100,-3000+row*100,row*55+col);
        point(599+col*100,-2901+row*100,row*55+col);
      end
    point(499,0,-1);point(6000,0,-1);point(1000,-3001,-1);point(1000,3000,-1);
    if(accepted!==6600||roi!==4)$fatal(1,"COUNTERS accepted=%0d roi=%0d",accepted,roi);
    $display("GRID_ADDRESS_PASS: 6600 boundary addresses and exact squared distances, 4 ROI rejects");$finish;
  end
  initial begin #2000000;$fatal(1,"TIMEOUT");end
endmodule
