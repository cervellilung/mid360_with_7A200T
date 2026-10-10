// Coherent held-bus transfer; continuous requests also refresh after a reset.
`timescale 1ns/1ps
module acx750_cdc_snapshot #(parameter integer WIDTH=3,
 parameter logic [WIDTH-1:0] RESET_VALUE='0)(
 input wire src_clk,src_rst_n,input wire [WIDTH-1:0] src_data,
 input wire dest_clk,dest_rst_n,output logic [WIDTH-1:0] dest_data);
 logic send=0;logic [WIDTH-1:0] held=RESET_VALUE;
 wire received,request;wire [WIDTH-1:0] transferred;
 always_ff @(posedge src_clk or negedge src_rst_n)
  if(!src_rst_n) begin send<=0;held<=RESET_VALUE;end
  else if(received) send<=0;
  else if(!send) begin held<=src_data;send<=1;end
 xpm_cdc_handshake #(.DEST_EXT_HSK(0),.DEST_SYNC_FF(2),.SRC_SYNC_FF(2),
 .INIT_SYNC_FF(1),.SIM_ASSERT_CHK(1),.WIDTH(WIDTH)) u_transfer(
 .src_clk(src_clk),.src_in(held),.src_send(send),.src_rcv(received),
 .dest_clk(dest_clk),.dest_ack(1'b0),.dest_req(request),.dest_out(transferred));
 always_ff @(posedge dest_clk or negedge dest_rst_n)
  if(!dest_rst_n) dest_data<=RESET_VALUE;
  else if(request) dest_data<=transferred;
endmodule
