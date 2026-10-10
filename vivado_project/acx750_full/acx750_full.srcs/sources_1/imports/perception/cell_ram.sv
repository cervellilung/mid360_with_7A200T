// ============================================================================
// 本文件从 fpga_ac880/sensor_perception_ar/rtl/cell_ram.sv 原样搬入，行为未改。
// 原文件名：cell_ram.sv
// 原路径：fpga_ac880/sensor_perception_ar/rtl/cell_ram.sv
// ============================================================================
`timescale 1ns/1ps
// Two synchronous read/write ports, no reset on the memory or read registers.
// Initialization is a sequenced write on port A. No third memory write port.
module cell_ram #(parameter WIDTH=233,DEPTH=3300)(input logic clk,
 input logic [11:0] a_addr,b_addr,input logic a_write,b_write,
 input logic [WIDTH-1:0] a_data,b_data,
 output logic [WIDTH-1:0] a_q,b_q);
 (* ram_style="block" *) logic [WIDTH-1:0] memory[0:DEPTH-1];
 always_ff @(posedge clk)begin
  if(a_write)memory[a_addr]<=a_data;
  a_q<=memory[a_addr];
 end
 always_ff @(posedge clk)begin
  if(b_write)memory[b_addr]<=b_data;
  b_q<=memory[b_addr];
 end
endmodule