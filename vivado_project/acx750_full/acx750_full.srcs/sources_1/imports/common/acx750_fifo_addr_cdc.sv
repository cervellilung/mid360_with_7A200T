// Address-clear CDC only; pixel data and FIFO reset interfaces are unchanged.
`timescale 1ns/1ps
module acx750_fifo_addr_cdc (
 input wire reset,
 input wire wr_clk, wr_clear,
 input wire rd_clk, rd_frame,
 input wire axi_clk,
 output wire wr_clear_axi, rd_frame_axi
);
 wire wr_level_axi, rd_reset;
 xpm_cdc_single #(.DEST_SYNC_FF(2), .INIT_SYNC_FF(1),
   .SRC_INPUT_REG(1), .SIM_ASSERT_CHK(0)) u_wr_level (
   .src_clk(wr_clk), .src_in(wr_clear),
   .dest_clk(axi_clk), .dest_out(wr_level_axi));
 assign wr_clear_axi = reset || wr_level_axi;

 // Global adapter reset is synchronous in AXI; release it in the read domain.
 xpm_cdc_async_rst #(.DEST_SYNC_FF(2), .INIT_SYNC_FF(1),
   .RST_ACTIVE_HIGH(1)) u_rd_reset (
   .src_arst(reset), .dest_clk(rd_clk), .dest_arst(rd_reset));
 // One source-cycle SOF becomes exactly one AXI-cycle event. The frame period
 // greatly exceeds the XPM minimum event spacing; do not use for per-pixel data.
 xpm_cdc_pulse #(.DEST_SYNC_FF(2), .INIT_SYNC_FF(1),
   .REG_OUTPUT(1), .RST_USED(1), .SIM_ASSERT_CHK(1)) u_rd_event (
   .src_clk(rd_clk), .src_pulse(rd_frame), .src_rst(rd_reset),
   .dest_clk(axi_clk), .dest_rst(reset), .dest_pulse(rd_frame_axi));
endmodule
