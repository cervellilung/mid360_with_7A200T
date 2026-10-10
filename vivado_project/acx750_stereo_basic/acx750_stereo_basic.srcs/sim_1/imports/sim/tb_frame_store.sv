`timescale 1ns/1ps
module tb_frame_store;
 localparam N=16;
 logic clk=0;always #5 clk=~clk;
 logic rst=1,valid=0,sof=0,eof=0,take=0,release_slot=0,release_bank=0,ren=0,rb=0;
 logic [3:0] address=0;logic [24:0] data=0;logic [31:0] id=0;logic [63:0] stamp=0;
 wire ready,bank;wire [31:0] rid,drop,bad;wire [63:0] ts;wire [24:0] q;
 stereo_frame_store #(.PIXELS(N)) dut(clk,rst,valid,sof,eof,data,id,stamp,
 ready,bank,rid,ts,take,release_slot,release_bank,ren,rb,address,q,drop,bad);
 task frame(input integer number,length);
  id=number;stamp=number*100;
  for(integer k=0;k<length;k=k+1)begin
   @(negedge clk);valid=1;sof=k==0;eof=k==length-1;data=number*32+k;
  end
  @(negedge clk);valid=0;sof=0;eof=0;
 endtask
 task claim;
  @(negedge clk);rb=bank;take=1;
  @(negedge clk);take=0;
 endtask
 task release_read;
  @(negedge clk);release_slot=1;release_bank=rb;
  @(negedge clk);release_slot=0;
 endtask
 initial begin
  repeat(4)@(negedge clk);rst=0;
  frame(1,N);frame(2,N);
  if(!ready||rid!=1)$fatal(1,"Oldest complete frame not selected");
  claim();frame(3,N);
  if(drop!=1||rid!=2)$fatal(1,"Reading slot overwritten or full frame not dropped");
  for(integer k=0;k<N;k=k+1)begin
   @(negedge clk);ren=1;address=k;
   @(negedge clk);ren=0;
   if(q!==25'(32+k))$fatal(1,"Reading ownership corrupted at %0d",k);
  end
  release_read();claim();release_read();
  frame(4,5);
  if(ready||bad!=1)$fatal(1,"Truncated frame exposed");
  frame(5,N+1);
  if(ready||bad==1)$fatal(1,"Oversized frame exposed");
  frame(6,N);
  if(!ready||rid!=6)$fatal(1,"Recovery failed");
  @(negedge clk);rst=1;
  @(negedge clk);rst=0;
  if(ready||drop||bad)$fatal(1,"Reset retained old ownership");
  frame(7,N);if(!ready||rid!=7)$fatal(1,"Post-reset recovery failed");
  $display("PASS frame_store ownership overflow truncation reset");$finish;
 end
 initial begin #100000;$fatal(1,"Timeout");end
endmodule
