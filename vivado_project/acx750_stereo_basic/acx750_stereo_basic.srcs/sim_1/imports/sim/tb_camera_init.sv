`timescale 1ns/1ps
module tb_camera_init;
 logic clk=0,xclk=0,rst=1;
 always #10 clk=~clk;
 always #20.833 xclk=~xclk;
 wire [1:0] cam_clk,cam_rst,pwdn,scl,done,failed;
 tri1 [1:0] sda;
 stereo_camera_init #(.RESET_CYCLES(4),.TIMEOUT_CYCLES(64)) dut(
 clk,rst,xclk,cam_clk,cam_rst,pwdn,scl,sda,done,failed);
 initial begin
  repeat(20)@(negedge clk);rst=0;
  repeat(3)@(negedge clk);if(cam_rst!=0)$fatal(1,"Camera reset released early");
  repeat(5)@(negedge clk);if(cam_rst!=3)$fatal(1,"Power-on reset never released");
  repeat(70)@(negedge clk);
  if(failed!=3||done!=0||cam_rst!=0)$fatal(1,"Unconfigured camera failed to timeout safely");
  rst=1;repeat(3)@(negedge clk);
  if(failed||done)$fatal(1,"Reset did not clear initialization failure");
  rst=0;repeat(80)@(negedge clk);
  if(failed!=3||done)$fatal(1,"Initialization retry failed");
  $display("PASS camera_init power_reset timeout retry");$finish;
 end
endmodule
