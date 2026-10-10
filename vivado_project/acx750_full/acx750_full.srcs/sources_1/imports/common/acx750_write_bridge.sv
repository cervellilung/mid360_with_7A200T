`timescale 1ns/1ps
// Independent source clocks; no clock multiplexing on the DDR write port.
module acx750_write_bridge #(
  parameter integer DEPTH = 2048
) (
  input wire sys_clk, input wire rst_n, input wire flush,
  input wire [2:0] stage,
  input wire pix_clk, input wire pix_valid, input wire [15:0] pix_data,
  input wire eth_clk, input wire eth_valid, input wire [15:0] eth_data,
  input wire cam_clk, input wire cam_valid, input wire [15:0] cam_data,
  input wire out_ready,
  output wire out_valid, output wire [15:0] out_data,
  output wire [2:0] overflow
);
  localparam integer CW = $clog2(DEPTH)+1;
  wire [2:0] source_clk = {cam_clk, eth_clk, pix_clk};
  wire [2:0] source_valid = {cam_valid, eth_valid, pix_valid};
  wire [15:0] source_data [0:2];
  assign source_data[0] = pix_data;
  assign source_data[1] = eth_data;
  assign source_data[2] = cam_data;
  wire [15:0] data [0:2];
  wire [2:0] empty, rd_busy, pop;
  wire clear_n = rst_n && !flush;
  wire selected = stage >= 1 && stage <= 3;
  wire [1:0] index = stage[1:0]-1'b1;
  assign out_valid = clear_n && selected && !empty[index] && !rd_busy[index];
  assign out_data = selected ? data[index] : 16'd0;

  genvar g;
  generate for (g=0;g<3;g=g+1) begin : lanes
    // Reset holds even if the camera clock is temporarily absent; release
    // requires five source edges, followed by XPM's own reset-busy interval.
    wire reset, active;
    xpm_cdc_async_rst #(.DEST_SYNC_FF(5),.INIT_SYNC_FF(1),.RST_ACTIVE_HIGH(1))
      u_reset(.src_arst(!clear_n),.dest_clk(source_clk[g]),.dest_arst(reset));
    // Register one-hot selection in its source domain, then synchronize.
    xpm_cdc_single #(.DEST_SYNC_FF(2),.INIT_SYNC_FF(1),.SRC_INPUT_REG(1))
      u_active(.src_clk(sys_clk),.src_in(clear_n && stage == g+1),
        .dest_clk(source_clk[g]),.dest_out(active));
    wire full, wr_busy;
    reg dropped;
    wire drop_sync;
    always @(posedge source_clk[g] or posedge reset)
      if (reset) dropped <= 0;
      else if (active && source_valid[g] && full && !wr_busy)
        dropped <= 1;
    xpm_cdc_single #(.DEST_SYNC_FF(2),.INIT_SYNC_FF(1),.SRC_INPUT_REG(0))
      u_drop(.src_clk(source_clk[g]),.src_in(dropped),
        .dest_clk(sys_clk),.dest_out(drop_sync));
    assign overflow[g] = drop_sync;
    assign pop[g] = out_valid && out_ready && index == g;
    xpm_fifo_async #(
      .FIFO_MEMORY_TYPE("block"), .FIFO_WRITE_DEPTH(DEPTH),
      .WRITE_DATA_WIDTH(16), .READ_DATA_WIDTH(16),
      .READ_MODE("fwft"), .FIFO_READ_LATENCY(0),
      .CDC_SYNC_STAGES(2), .DOUT_RESET_VALUE("0"),
      .WR_DATA_COUNT_WIDTH(CW), .RD_DATA_COUNT_WIDTH(CW),
      .USE_ADV_FEATURES("0000"), .SIM_ASSERT_CHK(0)
    ) fifo (
      .rst(reset), .wr_clk(source_clk[g]), .rd_clk(sys_clk),
      .din(source_data[g]),
      .wr_en(!reset && active && source_valid[g] && !full && !wr_busy),
      .rd_en(pop[g]), .dout(data[g]), .full(full), .empty(empty[g]),
      .wr_rst_busy(wr_busy), .rd_rst_busy(rd_busy[g]),
      .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0),
      .almost_empty(), .almost_full(), .data_valid(), .dbiterr(),
      .overflow(), .prog_empty(), .prog_full(), .rd_data_count(),
      .sbiterr(), .underflow(), .wr_ack(), .wr_data_count()
    );
  end endgenerate
endmodule
