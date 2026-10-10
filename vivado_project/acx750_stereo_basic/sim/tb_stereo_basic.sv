`timescale 1ns/1ps
module tb_stereo_basic;
 localparam W=80,H=12,N=W*H;
 logic clk=0;always #5 clk=~clk;
 logic rst=1,lv=0,ls=0,le=0,rv=0,rs=0,re=0,cal=1,lwe=0;
 logic [7:0] lg,rg;logic [6:0] la;logic [15:0] lm;
 logic [31:0] lid=7,rid=7;logic [63:0] lt=10000,rt=10050;
 wire dv,dg,busy;logic ready=1;wire [15:0] mm;wire [6:0] disp;
 wire [$clog2(W)-1:0] x;wire [$clog2(H)-1:0] y;
 wire [31:0] fid,dl,dr,bl,br,rp,prid;wire [63:0] ts;
 stereo_pair_engine #(.WIDTH(W),.HEIGHT(H)) dut(
 .clk(clk),.rst(rst),.l_valid(lv),.l_sof(ls),.l_eof(le),.l_gray(lg),.l_id(lid),.l_stamp(lt),
 .r_valid(rv),.r_sof(rs),.r_eof(re),.r_gray(rg),.r_id(rid),.r_stamp(rt),.calibration_valid(cal),
 .lut_we(lwe),.lut_address(la),.lut_mm(lm),.max_cost(6'd6),.uniqueness(6'd2),
 .depth_valid(dv),.depth_good(dg),.depth_ready(ready),.depth_mm(mm),.disparity(disp),.x(x),.y(y),.frame_id(fid),.stamp_us(ts),
 .dropped_left(dl),.dropped_right(dr),.bad_left(bl),.bad_right(br),.rejected_pairs(rp),.pair_busy(busy),.pair_right_id(prid));
 logic [15:0] gray[0:N-1],expected[0:N-1];integer got=0,good=0,cycle=0;
 logic expect_depth=1;
 localparam OUT_BITS=1+16+7+$clog2(W)+$clog2(H)+32+64;
 logic hold=0;logic [OUT_BITS-1:0] held;
 wire [OUT_BITS-1:0] output_bus={dg,mm,disp,x,y,fid,ts};
 always @(negedge clk)if(!rst)begin cycle=cycle+1;ready=(cycle%11!=0&&cycle%11!=1&&cycle%11!=2);end
 always @(posedge clk)if(!rst)begin
  if(hold&&output_bus!==held)$fatal(1,"Elastic output changed during backpressure");
  hold=dv&&!ready;held=output_bus;
  if(dv&&ready)begin
   if(got>=N)$fatal(1,"Extra output");
   if(disp!==expected[got][12:6]||dg!==(expected[got][13]&&expect_depth))$fatal(1,"Disparity mismatch pixel %0d: d=%0d good=%0d expected=%h",got,disp,dg,expected[got]);
   if(x!==(got%W>=2?got%W-2:0)||y!==(got/W>=2?got/W-2:0)||fid!=7||ts!=10000)$fatal(1,"Metadata mismatch %0d",got);
   if(dg)begin good=good+1;if(mm!=10000/disp)$fatal(1,"Depth LUT mismatch");end
   else if(mm!==16'd0)$fatal(1,"Invalid depth leaked an uninitialized/nonzero distance");
   got=got+1;
  end
 end
 task send_frame;
  for(integer k=0;k<N;k=k+1)begin
   @(negedge clk);lv=1;rv=1;ls=k==0;rs=k==0;le=k==N-1;re=k==N-1;lg=gray[k][15:8];rg=gray[k][7:0];
   if(k%7==0)begin @(negedge clk);lv=0;rv=0;ls=0;rs=0;le=0;re=0;end
  end
  @(negedge clk);lv=0;rv=0;ls=0;rs=0;le=0;re=0;
 endtask
 initial begin
  $readmemh("gray.hex",gray);$readmemh("match.hex",expected);
  repeat(5)@(negedge clk);rst=0;
  for(integer k=0;k<128;k=k+1)begin @(negedge clk);lwe=1;la=k;lm=k==0?0:10000/k;end
  @(negedge clk);lwe=0;send_frame();
  wait(got==N);repeat(15)@(negedge clk);
  if(good<300||bl||br||dl||dr||rp)$fatal(1,"Insufficient depth or frame errors good=%0d",good);
  // Grossly mismatched timestamps: older complete frame must be rejected, never fused.
  lt=20000;rt=40000;send_frame();repeat(20)@(negedge clk);
  if(rp!=1||got!=N||busy)$fatal(1,"Skew rejection failed");
  // Reset invalidates the LUT load bitmap without clearing its RAM contents.
  @(negedge clk);rst=1;hold=0;
  repeat(3)@(negedge clk);rst=0;got=0;good=0;lt=10000;rt=10050;expect_depth=0;
  send_frame();wait(got==N);repeat(10)@(negedge clk);
  if(good!=0)$fatal(1,"Unloaded calibration accepted");
  $display("PASS stereo_basic pixels=%0d valid=%0d cycles=%0d",got,good,cycle);$finish;
 end
 initial begin #2000000;$fatal(1,"Timeout");end
endmodule
