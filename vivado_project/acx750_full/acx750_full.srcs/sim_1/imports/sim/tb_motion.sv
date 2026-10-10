//============================================================================
// 来源：fpga_ac880/sensor_perception_ar/tests/tb_motion.sv，仅调整路径。
// 说明：从 7020（XC7Z020）工程原样搬入 ACX750 新工程，被测逻辑零改动。
//       本文件本身不含任何文件路径。
//============================================================================
`timescale 1ns/1ps
module tb_motion;
 reg clk=0,rst=1,fv=0;always #5 clk=~clk;
 reg signed [15:0] vx=0,vy=0;reg [63:0] now_us=0;
 wire valid,updated;wire [31:0] speed,filtered,rejected,overflow;wire [63:0] distance_um,last;
 chassis_motion dut(clk,rst,fv,vx,vy,now_us,valid,updated,speed,filtered,distance_um,last,rejected,overflow);
 task step(input integer a,b,input [63:0] t,input [31:0] es,ef,input [63:0] ed);
 begin @(negedge clk);vx=a;vy=b;now_us=t;fv=1;@(negedge clk);fv=0;wait(updated);#1;
 if(speed!==es||filtered!==ef||distance_um!==ed)$fatal(1,"motion got %d %d %d expected %d %d %d",speed,filtered,distance_um,es,ef,ed);end endtask
 initial begin
  #25;rst=0;step(5000,0,1000,1000,1000,0);step(-5000,0,21000,1000,1000,20000);
  step(0,5000,41000,1000,1000,40000);step(0,0,61000,0,875,58750);
  @(negedge clk);now_us=300000;fv=1;@(negedge clk);fv=0;repeat(4)@(posedge clk);
  if(rejected!=1||distance_um!=58750)$fatal(1,"bad dt integrated");
  step(0,0,320000,0,765,75150);
  now_us=1320001;#1;if(valid)$fatal(1,"stale motion");
  @(negedge clk);rst=1;repeat(3)@(negedge clk);rst=0;
  step(-32768,-32768,1,9268,9268,0);
  step(-32768,-32768,100001,9268,9268,926800);
  step(32767,32767,200001,9267,9267,1853550);
  step(-32768,0,200002,6553,8927,1853559);
  step(-32768,0,200003,6553,8630,1853567);
  $display("PASS motion, extreme signed velocities, maximum dt, preserved remainder");$finish;
 end
 initial begin #100000;$fatal(1,"motion timeout");end
endmodule