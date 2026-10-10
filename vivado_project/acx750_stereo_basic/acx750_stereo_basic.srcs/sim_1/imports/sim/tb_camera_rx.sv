`timescale 1ns/1ps
module tb_camera_rx;
 localparam W=8,H=4,N=W*H;
 logic clk=0;always #5 clk=~clk;
 logic [1:0] pclk=0;always #6.5 pclk[0]=~pclk[0];always #8.5 pclk[1]=~pclk[1];
 logic rst=1,configured=0;
 logic [1:0] vs=2'b11,hs=0,ready=2'b11;
 logic [7:0] data[0:1];wire [1:0] valid,sof,eof,overflow;
 wire [15:0] rgb[0:1];wire [31:0] id[0:1],good[0:1],bad[0:1];wire [63:0] stamp[0:1];
 logic [63:0] now_us=0;
 always @(posedge clk)now_us<=now_us+1;
 for(genvar k=0;k<2;k=k+1)begin:lanes
  stereo_camera_rx #(.WIDTH(W),.HEIGHT(H),.FIFO_DEPTH(64),.SKIP_FRAMES(0)) dut(
   clk,rst,configured,now_us,pclk[k],vs[k],hs[k],data[k],valid[k],ready[k],rgb[k],sof[k],eof[k],id[k],stamp[k],good[k],bad[k],overflow[k]);
  // Independent checks replace the flawed 2020.2 one-cycle async-pointer SVA.
  always @(posedge pclk[k])begin
   if($isunknown(dut.fifo.wr_en))$fatal(1,"Unknown FIFO write enable");
   if(dut.fifo.wr_en&&(dut.full||dut.wb||rst||dut.prst))$fatal(1,"Illegal FIFO write");
  end
  always @(posedge clk)begin
   if($isunknown(dut.fifo.rd_en))$fatal(1,"Unknown FIFO read enable");
   if(dut.fifo.rd_en&&(dut.empty||dut.rb||rst||dut.srst))$fatal(1,"Illegal FIFO read");
  end
 end
 integer cursor[0:1]='{0,0},ends[0:1]='{0,0};
 logic [114:0] held[0:1];logic [1:0] holding=0;
 logic [31:0] fid[0:1];logic [63:0] fstamp[0:1];
 logic [1:0] pixel_error=0;
 always @(posedge clk)if(!rst)for(integer k=0;k<2;k=k+1)begin
  if(holding[k]&&{valid[k],rgb[k],sof[k],eof[k],id[k],stamp[k]}!==held[k])$fatal(1,"CDC output changed under backpressure lane %0d",k);
  holding[k]=valid[k]&&!ready[k];held[k]={valid[k],rgb[k],sof[k],eof[k],id[k],stamp[k]};
  if(valid[k]&&ready[k])begin
   if(sof[k])begin cursor[k]=0;fid[k]=id[k];fstamp[k]=stamp[k];pixel_error[k]=0;end
   if(rgb[k]!==16'(16'h1000+k*256+cursor[k]))pixel_error[k]=1;
   if(id[k]!=fid[k]||stamp[k]!=fstamp[k])$fatal(1,"Frame metadata changed");
   cursor[k]=cursor[k]+1;
   if(eof[k])begin if(cursor[k]!=N||pixel_error[k])$fatal(1,"Invalid frame committed lane %0d length %0d",k,cursor[k]);ends[k]=ends[k]+1;end
  end
 end
 task send_left(input integer short_line);
  @(negedge pclk[0]);vs[0]=0;
  repeat(4)@(negedge pclk[0]);
  for(integer y=0;y<H;y=y+1)begin
   for(integer x=0;x<(short_line&&y==H-1?W-1:W);x=x+1)begin
    @(negedge pclk[0]);hs[0]=1;data[0]=(16'h1000+0*256+y*W+x)>>8;
    @(negedge pclk[0]);data[0]=16'h1000+0*256+y*W+x;
   end
   @(negedge pclk[0]);hs[0]=0;
   repeat(4)@(negedge pclk[0]);
  end
  @(negedge pclk[0]);vs[0]=1;
  repeat(8)@(negedge pclk[0]);
 endtask
 task send_right(input integer short_line);
  @(negedge pclk[1]);vs[1]=0;
  repeat(4)@(negedge pclk[1]);
  for(integer y=0;y<H;y=y+1)begin
   for(integer x=0;x<(short_line&&y==H-1?W-1:W);x=x+1)begin
    @(negedge pclk[1]);hs[1]=1;data[1]=(16'h1000+1*256+y*W+x)>>8;
    @(negedge pclk[1]);data[1]=16'h1000+1*256+y*W+x;
   end
   @(negedge pclk[1]);hs[1]=0;
   repeat(4)@(negedge pclk[1]);
  end
  @(negedge pclk[1]);vs[1]=1;
  repeat(8)@(negedge pclk[1]);
 endtask
 integer saved;
 initial begin
  repeat(30)@(negedge clk);rst=0;configured=1;
  repeat(70)@(negedge clk);
  fork send_left(0);send_right(0);join
  repeat(50)@(negedge clk);
  if(ends[0]!=1||ends[1]!=1||good[0]!=1||good[1]!=1||bad[0]||bad[1])$fatal(1,"Independent PCLK acquisition failed");
  send_left(1);repeat(50)@(negedge clk);
  if(ends[0]!=1||bad[0]!=1)$fatal(1,"Short line committed");
  @(negedge clk);ready[0]=0;
  repeat(4)send_left(0);
  @(negedge clk);ready[0]=1;
  repeat(1000)@(negedge clk);
  if(!overflow[0]||bad[0]<2)$fatal(1,"Overflow not exposed as bad frame");
  saved=ends[0];send_left(0);repeat(100)@(negedge clk);
  if(ends[0]!=saved+1)$fatal(1,"Overflow recovery failed");
  $display("PASS camera_rx independent_PCLK RGB565 short_line overflow recovery");$finish;
 end
 initial begin #200000;$fatal(1,"Timeout");end
endmodule
