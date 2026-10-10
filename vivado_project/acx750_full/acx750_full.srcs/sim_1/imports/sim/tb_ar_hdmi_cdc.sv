`timescale 1ns/1ps
module tb_ar_hdmi_cdc;
 logic control_clk=0,clk=0,control_rst=1,rst=1,publish=0;
 always #5 control_clk=~control_clk;
 always #9.75609756 clk=~clk;
 logic [1:0] boxes=0;
 logic [21:0] bx0=0,bx1=0;
 logic [19:0] by0=0,by1=0;
 logic [11:0] shifts=0;
 logic stereo=0,test_mode=0,motion_valid=1;
 logic [31:0] radar_age_us=0,motion_age_us=0,nearest_mm=1000,speed_mm_s=500,travel_mm=5000;
 logic [1:0] risk=0;
 logic [15:0] s_data=0;
 logic s_valid=0,s_sof=0,s_eol=0,m_ready=1;
 wire publish_ready,s_ready,m_valid,m_sof,m_eol;
 wire [15:0] m_data;
 wire gold_publish_ready,gold_s_ready,gold_m_valid,gold_m_sof,gold_m_eol;
 wire [15:0] gold_m_data;
 ar_video #(.BOXES(2),.VIDEO_HZ(51_250_000)) dut(.*);
 ar_video_before_hdmi_cdc #(.BOXES(2),.VIDEO_HZ(51_250_000)) golden(
  .publish_ready(gold_publish_ready),.s_ready(gold_s_ready),
  .m_data(gold_m_data),.m_valid(gold_m_valid),.m_sof(gold_m_sof),.m_eol(gold_m_eol),.*);
 integer pixel=0,frames=0,accepted=0,coloured=0,changes=0,green_pixels=0,cyan_pixels=0;
 logic advance_input=0;
 logic [15:0] random_state=16'h1234;
 // Hold the input pixel until accepted; downstream ready varies independently.
 always @(negedge clk) begin
  if(rst)begin s_valid=0;s_sof=0;s_eol=0;s_data=0;pixel=0;m_ready=1;end
  else begin
   if(advance_input)begin
    if(pixel==959)begin pixel=0;frames=frames+1;end else pixel=pixel+1;
   end
   random_state={random_state[14:0],random_state[15]^random_state[13]^random_state[12]^random_state[10]};
   m_ready=random_state[0]||random_state[2];
   s_valid=1;s_sof=(pixel==0);s_eol=(pixel%40==39);s_data=16'h1234;
  end
 end
 always @(posedge clk) begin
  advance_input=!rst && s_valid && s_ready;
  if(!rst && m_valid && m_ready)begin
   accepted=accepted+1;
   if(m_data!=16'h1234)coloured=coloured+1;
   if(m_data==16'h07e0)green_pixels=green_pixels+1;
   if(m_data==16'h07ff)cyan_pixels=cyan_pixels+1;
  end
  #0.1;
  if(!rst)begin
   if({s_ready,m_valid,m_sof,m_eol,m_data} !== {gold_s_ready,gold_m_valid,gold_m_sof,gold_m_eol,gold_m_data})
    $fatal(1,"AR cycle mismatch at frame %0d pixel %0d",frames,pixel);
  end
 end
 always @(posedge control_clk)begin
  #0.1;
  if(!control_rst && publish_ready!==gold_publish_ready)$fatal(1,"Handshake timing changed");
 end
 initial begin
  #400;@(negedge control_clk);control_rst=0;@(negedge clk);rst=0;
  repeat(8)begin
   wait(publish_ready);@(negedge control_clk);
   boxes=2'b11;bx0={11'd22,11'd4};bx1={11'd31,11'd12};
   by0={10'd2,10'd1};by1={10'd5,10'd4};shifts={6'd2,6'd1};
   stereo=changes[0];risk=changes%3;nearest_mm=1000+changes*100;
   publish=1;@(negedge control_clk);publish=0;changes=changes+1;
   #1000;wait(!publish_ready);wait(publish_ready);
  end
  wait(frames>=10);
  @(negedge control_clk);control_rst=1;rst=1;
  #400;@(negedge control_clk);control_rst=0;@(negedge clk);rst=0;
  wait(frames>=12);#200;
  if(accepted<10000 || coloured<100 || changes!=8 || green_pixels<20 || cyan_pixels<20)$fatal(1,"Insufficient coverage");
  $display("PASS tb_ar_hdmi_cdc exact-cycle pixels=%0d green=%0d cyan=%0d publishes=%0d",accepted,green_pixels,cyan_pixels,changes);
  $finish;
 end
 initial begin #2000000;$fatal(1,"Timeout");end
endmodule
