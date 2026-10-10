`timescale 1ns/1ps
// Explicit legal BRAM aspect ratios avoid rounding deep byte RAMs to 3x32K.
// Read latency: one clock. Tile select is registered with parallel tile reads.
module stereo_tiled_ram #(parameter integer DEPTH=76800,BITS=8,
 TILE_DEPTH=(BITS==1?32768:4096))(
 input logic clk,we,input logic [$clog2(DEPTH)-1:0] wa,
 input logic [BITS-1:0] wd,input logic re,
 input logic [$clog2(DEPTH)-1:0] ra,output logic [BITS-1:0] rd);
 localparam integer TW=$clog2(TILE_DEPTH),NT=(DEPTH+TILE_DEPTH-1)/TILE_DEPTH,
 SW=(NT>1?$clog2(NT):1);
 wire [SW-1:0] write_tile=wa>>TW,read_tile=ra>>TW;
 logic [SW-1:0] selected;
 wire [BITS-1:0] q[0:NT-1];
 always_ff @(posedge clk)if(re)selected<=read_tile;
 for(genvar t=0;t<NT;t=t+1)begin:tile
  (* ram_style="block" *)logic [BITS-1:0] mem[0:TILE_DEPTH-1];
  logic [BITS-1:0] value;
  always_ff @(posedge clk)begin
   if(we&&write_tile==t)mem[wa[TW-1:0]]<=wd;
   if(re)value<=mem[ra[TW-1:0]];
  end
  assign q[t]=value;
 end
 assign rd=q[selected];
endmodule
