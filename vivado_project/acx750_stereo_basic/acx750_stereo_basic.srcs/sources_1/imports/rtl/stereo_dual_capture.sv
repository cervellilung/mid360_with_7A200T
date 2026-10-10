`timescale 1ns/1ps
// Capture subsystem only. Raw RGB must pass real rectification before depth.
module stereo_dual_capture #(parameter integer WIDTH=640,HEIGHT=480,SKIP_FRAMES=10)(
 input wire sys_clk,clk50,xclk24,arst,input wire [63:0] now_us,
 input wire [1:0] pclk,vsync,href,input wire [7:0] data[0:1],
 output wire [1:0] camera_xclk,camera_rst_n,camera_pwdn,scl,
 inout wire [1:0] sda,
 output wire [1:0] configured,failed,overflow_seen,
 output wire [1:0] valid,sof,eof,input wire [1:0] ready,
 output wire [15:0] rgb[0:1],output wire [31:0] frame_id[0:1],
 output wire [63:0] stamp_us[0:1],output wire [31:0] complete_frames[0:1],bad_frames[0:1]);
 wire control_rst;wire [1:0] done50,failed50;
 xpm_cdc_async_rst #(.DEST_SYNC_FF(2),.INIT_SYNC_FF(0),.RST_ACTIVE_HIGH(1))
  control_reset(.src_arst(arst),.dest_clk(clk50),.dest_arst(control_rst));
 stereo_camera_init #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) init(
  clk50,control_rst,xclk24,camera_xclk,camera_rst_n,camera_pwdn,scl,sda,done50,failed50);
 for(genvar k=0;k<2;k=k+1)begin:camera
  // done50 includes fault/reset qualification: register before crossing domains.
  xpm_cdc_single #(.DEST_SYNC_FF(2),.INIT_SYNC_FF(1),.SRC_INPUT_REG(1))
   init_status(.src_clk(clk50),.src_in(done50[k]),.dest_clk(sys_clk),.dest_out(configured[k]));
  xpm_cdc_single #(.DEST_SYNC_FF(2),.INIT_SYNC_FF(1),.SRC_INPUT_REG(0))
   init_fault(.src_clk(clk50),.src_in(failed50[k]),.dest_clk(sys_clk),.dest_out(failed[k]));
  stereo_camera_rx #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.SKIP_FRAMES(SKIP_FRAMES)) rx(
   sys_clk,arst,configured[k],now_us,pclk[k],vsync[k],href[k],data[k],
   valid[k],ready[k],rgb[k],sof[k],eof[k],frame_id[k],stamp_us[k],
   complete_frames[k],bad_frames[k],overflow_seen[k]);
 end
endmodule
