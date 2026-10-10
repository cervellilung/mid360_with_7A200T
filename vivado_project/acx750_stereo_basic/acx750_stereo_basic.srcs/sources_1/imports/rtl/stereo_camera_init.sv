`timescale 1ns/1ps
// ch54 SCCB register tables are reused at their required 50 MHz control clock.
// Shared XCLK/configuration does not prove synchronized exposure.
module stereo_camera_init #(parameter integer WIDTH=640,HEIGHT=480,
 RESET_CYCLES=50000,TIMEOUT_CYCLES=100000000)(
 input logic clk50,rst,input logic xclk24,
 output wire [1:0] camera_xclk,camera_rst_n,camera_pwdn,scl,
 inout wire [1:0] sda,output wire [1:0] configured,failed);
 localparam PW=(RESET_CYCLES<2?1:$clog2(RESET_CYCLES+1)),
 TW=(TIMEOUT_CYCLES<2?1:$clog2(TIMEOUT_CYCLES+1));
 logic [PW-1:0] power_count;
 always_ff @(posedge clk50)begin
  if(rst)power_count<=0;
  else if(power_count<RESET_CYCLES)power_count<=power_count+1'b1;
 end
 assign camera_xclk={2{xclk24}};
 for(genvar k=0;k<2;k=k+1)begin:camera
  wire done;
  logic fault;logic [TW-1:0] wait_count;
  wire run=!rst&&!fault&&power_count==RESET_CYCLES;
  camera_init #(.CAMERA_TYPE("ov5640"),.IMAGE_TYPE(0),.IMAGE_WIDTH(WIDTH),
   .IMAGE_HEIGHT(HEIGHT),.IMAGE_FLIP_EN(1),.IMAGE_MIRROR_EN(0)) vendor_init(
   .Clk(clk50),.Rst_n(run),.Init_Done(done),.camera_rst_n(),.camera_pwdn(),
   .i2c_sclk(scl[k]),.i2c_sdat(sda[k]));
  assign camera_rst_n[k]=run;
  assign camera_pwdn[k]=1'b0;
  assign configured[k]=done&&!fault&&!rst;
  assign failed[k]=fault;
  always_ff @(posedge clk50)begin
   if(rst)begin fault<=0;wait_count<=0;end
   else if(run&&!done)begin
    if(wait_count==TIMEOUT_CYCLES-1)fault<=1;
    else wait_count<=wait_count+1'b1;
   end
  end
 end
endmodule
