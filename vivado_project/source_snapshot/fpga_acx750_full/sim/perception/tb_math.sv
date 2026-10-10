//============================================================================
// 来源：fpga_ac880/sensor_perception_ar/tests/tb_math.sv，仅调整路径。
// 说明：从 7020（XC7Z020）工程原样搬入 ACX750 新工程，被测逻辑零改动。
//       本文件本身不含任何文件路径；`include "perception_types.svh" 由
//       编译器 -i 指向 fpga_acx750_full/rtl/perception/ 解析。
//============================================================================
`timescale 1ns/1ps
module tb_math;
 reg clk=0,rst=1,start=0;always #5 clk=~clk;
 reg [63:0] n;reg [31:0] d;wire bd,dd,bs,ds;wire [63:0] q;wire [31:0] rem,root;
 unsigned_div64 dv(clk,rst,start,n,d,bd,dd,q,rem);
 integer_sqrt64 sq(clk,rst,start,n,bs,ds,root);
 task test(input [63:0] a,input [31:0] b,input [31:0] expect_root);
 begin
  @(negedge clk);n=a;d=b;start=1;@(negedge clk);start=0;
  wait(ds);#1;if(root!==expect_root)$fatal(1,"sqrt %d got %d expected %d",a,root,expect_root);
  wait(dd);#1;if(q!==a/b||rem!==a%b)$fatal(1,"divide");
 end endtask
 initial begin #25;rst=0;test(0,1,0);test(1,1,1);test(2,3,1);test(1000000,17,1000);
 test(64'hffffffffffffffff,1234567,32'hffffffff);$display("PASS math");$finish;end
 initial begin #100000;$fatal(1,"timeout");end
endmodule