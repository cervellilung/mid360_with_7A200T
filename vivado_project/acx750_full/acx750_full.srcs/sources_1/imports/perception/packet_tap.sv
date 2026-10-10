// ============================================================================
// 本文件从 fpga_ac880/sensor_perception_ar/rtl/packet_tap.sv 原样搬入，行为未改。
// 原文件名：packet_tap.sv
// 原路径：fpga_ac880/sensor_perception_ar/rtl/packet_tap.sv
// ============================================================================
`timescale 1ns/1ps
// Nonblocking branch. s_valid denotes a transfer on the original DMA path.
// Busy branches discard entire records, including their last byte.
module packet_tap #(parameter MAX_BYTES=2048)(
 input logic clk,rst,input logic [7:0] s_data,input logic s_valid,s_last,
 output logic [7:0] m_data,output logic m_valid,m_last,input logic m_ready,
 output logic [31:0] drops);
 (* ram_style="block" *) logic [7:0] mem[0:MAX_BYTES-1];
 logic [$clog2(MAX_BYTES):0] wr,rd,length;
 logic sending,discarding;
 assign m_valid=sending;
 assign m_last=sending&&rd==length-1;
 assign m_data=mem[rd];
 always_ff @(posedge clk) begin
  if(rst) begin wr<=0;rd<=0;length<=0;sending<=0;discarding<=0;drops<=0;end
  else begin
   if(m_valid&&m_ready) begin
    if(m_last) begin sending<=0;rd<=0;end else rd<=rd+1;
   end
   if(s_valid) begin
    if(wr==0&&!discarding&&sending) begin
     drops<=drops+1;discarding<=!s_last;
    end else if(discarding) begin if(s_last) begin discarding<=0;wr<=0;end end
    else if(wr>=MAX_BYTES) begin
     drops<=drops+1;wr<=0;discarding<=!s_last;
    end else begin
     mem[wr]<=s_data;
     if(s_last) begin length<=wr+1;wr<=0;rd<=0;sending<=1;end
     else wr<=wr+1;
    end
   end
  end
 end
endmodule