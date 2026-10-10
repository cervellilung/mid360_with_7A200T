//============================================================================
// 来源：fpga_ac880/sensor_perception_ar/tests/tb_ar_compact.sv，仅调整路径。
// 说明：从 7020（XC7Z020）工程原样搬入 ACX750 新工程，被测逻辑零改动。
//       与 tb_ar 的区别是把 ar_video 的 COMPACT_HUD 参数置 1。
//       本文件本身不含任何文件路径。
//============================================================================
`timescale 1ns/1ps
module tb_ar_compact;
 logic clk=0,rst=1;always #5 clk=~clk;
 logic pub=0,ready;logic [31:0] boxes=1;logic [351:0] bx0=0,bx1=0;logic [319:0] by0=0,by1=0;logic [191:0] shifts=0;
 logic stereo=0;logic [31:0] age=0,near_input=1300,speed_input=1000,travel_input=20;
 logic [15:0] sd=16'h1234,md;logic sv=0,sf=0,se=0,sr,mv,mf,me,mr=1;
 logic [15:0] wanted[0:8191];logic wanted_f[0:8191],wanted_e[0:8191];integer put=0,get=0;
 logic [31:0] random_state=32'h1537;
 ar_video #(.VIDEO_HZ(1000000),.COMPACT_HUD(1)) dut(.control_clk(clk),.control_rst(rst),.publish(pub),.publish_ready(ready),
  .boxes(boxes),.bx0(bx0),.bx1(bx1),.by0(by0),.by1(by1),.shifts(shifts),.stereo(stereo),.test_mode(1'b0),
  .radar_age_us(age),.motion_age_us(32'd0),.nearest_mm(near_input),.speed_mm_s(speed_input),.travel_mm(travel_input),.motion_valid(1'b1),.risk(2'd2),
  .clk(clk),.rst(rst),.s_data(sd),.s_valid(sv),.s_sof(sf),.s_eol(se),.s_ready(sr),.m_data(md),.m_valid(mv),.m_sof(mf),.m_eol(me),.m_ready(mr));
 always @(negedge clk)if(!rst)begin random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};mr=random_state[0]|random_state[2];end
 always @(posedge clk)if(!rst&&mv&&mr)begin
  if(get>=put)$fatal(1,"unexpected pixel");
  if(md!==wanted[get]||mf!==wanted_f[get]||me!==wanted_e[get])$fatal(1,"pixel %d got%h expected%h",get,md,wanted[get]);
  get=get+1;
 end
 task pixel(input integer x,y,input [15:0] colour);begin
  @(negedge clk);sv=1;sf=x==0&&y==0;se=x==79;
  wanted[put]=colour;wanted_f[put]=sf;wanted_e[put]=se;put=put+1;
  @(posedge clk);while(!sr)@(posedge clk);
  @(negedge clk);sv=0;
 end endtask
 task publish;begin wait(ready);@(negedge clk);pub=1;@(negedge clk);pub=0;repeat(40)@(posedge clk);end endtask
 task frame(input integer mode);integer x,y,l,t,b,q,d;logic hit,r,c;logic [15:0] colour;begin
  l=bx0[0+:11];q=bx1[0+:11];t=by0[0+:10];b=by1[0+:10];d=shifts[0+:6];
  for(y=0;y<7;y=y+1)for(x=0;x<80;x=x+1)begin
   hit=x>=l&&x<=q&&y>=t&&y<=b&&(x-l<2||q-x<2||y-t<2||b-y<2);
   r=x>=l-d&&x<=q-d&&y>=t&&y<=b&&(x-(l-d)<2||(q-d)-x<2||y-t<2||b-y<2);
   c=x>=l+d&&x<=q+d&&y>=t&&y<=b&&(x-(l+d)<2||(q+d)-x<2||y-t<2||b-y<2);
   colour=16'h1234;
   if(mode==0&&hit)colour=16'hf800;
   if(mode==1)begin if(r&&c)colour=16'hffff;else if(r)colour=16'hf800;else if(c)colour=16'h07ff;end
   pixel(x,y,colour);
  end
  wait(get==put);
 end endtask
 initial begin bx0[0+:11]=20;bx1[0+:11]=40;by0[0+:10]=2;by1[0+:10]=5;shifts[0+:6]=3;
  #30;rst=0;publish();
  if(dut.holding[19:0]!==20'h01300)$fatal(1,"initial BCD conversion mismatch");
  frame(0);
  stereo=1;publish();frame(1);
  age=150001;publish();frame(2);
  age=0;stereo=1;bx0[0+:11]=0;bx1[0+:11]=2;by0[0+:10]=0;by1[0+:10]=0;shifts[0+:6]=63;publish();frame(1);
  bx0[0+:11]=60;bx1[0+:11]=79;by1[0+:10]=6;publish();frame(1);
  boxes=0;publish();frame(2);
  near_input=32'hffffffff;speed_input=99999;travel_input=32'hffffffff;
  publish();if(dut.holding[19:0]!==20'h67295)$fatal(1,"BCD maximum/modulo conversion mismatch");frame(2);
  near_input=0;speed_input=0;travel_input=0;
  publish();if(dut.holding[19:0]!==0)$fatal(1,"BCD zero conversion mismatch");frame(2);
  $display("PASS ar pixels, random backpressure, SOF update, stereo and stale boxes");$finish;
 end
 initial begin #1000000;$fatal(1,"AR timeout");end
endmodule