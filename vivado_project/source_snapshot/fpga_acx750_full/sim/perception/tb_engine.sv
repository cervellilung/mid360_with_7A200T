//============================================================================
// 来源：fpga_ac880/sensor_perception_ar/tests/tb_engine.sv，仅调整路径。
// 说明：从 7020（XC7Z020）工程原样搬入 ACX750 新工程，被测逻辑零改动。
//       本文件本身不含任何文件路径。
//============================================================================
`timescale 1ns/1ps
module tb_engine;
 logic clk=0,rst=1;always #5 clk=~clk;
 logic [63:0] now_us=0;
 always @(posedge clk)if(!rst)now_us<=now_us+100;
 logic [2047:0] cfg=0;logic [7071:0] lut=0;logic safe,ss,sb=0;logic [1023:0] meta;logic [383:0] obj;
 logic vr;logic [15:0] outd;logic ov,os,oe;integer snapshots=0;
 perception_engine dut(.clk(clk),.rst(rst),.now_us(now_us),.radar_data(8'd0),.radar_valid(1'b0),.radar_last(1'b0),
  .odom_data(8'd0),.odom_valid(1'b0),.odom_last(1'b0),.cfg(cfg),.lut(lut),.cfg_pending(1'b0),.cfg_safe(safe),
  .source_fifo_overflow(32'd0),.source_eth_rejected(32'd0),.source_odom_bad(32'd0),.source_odom_busy(32'd0),.source_radar_slot_drops(32'd0),.source_chassis_slot_drops(32'd0),
  .snapshot_start(ss),.metadata(meta),.snapshot_index(5'd0),.snapshot_busy(sb),.snapshot_object(obj),
  .video_clk(clk),.video_rst(rst),.video_data(16'd0),.video_valid(1'b0),.video_sof(1'b0),.video_eol(1'b0),
  .video_ready(vr),.out_data(outd),.out_valid(ov),.out_sof(os),.out_eol(oe),.out_ready(1'b1));
 always @(posedge clk)if(ss)begin
  if(meta[0+:32]!=32'h31524550||!meta[64+9]||meta[64+6])$fatal(1,"test snapshot flags");
  snapshots=snapshots+1;
 end
 initial begin
  cfg[64+:32]=32'h40000000;cfg[128+:32]=100;cfg[160+:32]=2;cfg[11*32+1]=1;
  #30;rst=0;repeat(8000)@(posedge clk);
  if(snapshots<5)$fatal(1,"test overlay must work without lidar");
  $display("PASS engine independent synthetic overlay heartbeat and validity flags");$finish;
 end
endmodule