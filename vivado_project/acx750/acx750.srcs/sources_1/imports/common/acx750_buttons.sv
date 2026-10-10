// Board S1..S4: previous, next, camera, colorbar. S0 stays reset.
`timescale 1ns/1ps
module acx750_buttons #(parameter integer DEBOUNCE_CYCLES=1_000_000)(
 input logic clk, rst_n, input logic [3:0] buttons_n,
 input logic [2:0] stage, output logic command_valid, output logic [7:0] command_data
);
 localparam integer CW=(DEBOUNCE_CYCLES<2)?1:$clog2(DEBOUNCE_CYCLES);
 (* ASYNC_REG="TRUE" *) logic [3:0] sync1, sync2;
 logic [3:0] stable_n, press;
 logic [CW-1:0] count[0:3];
 always_ff @(posedge clk or negedge rst_n)
  if (!rst_n) begin sync1<=4'hf;sync2<=4'hf; end
  else begin sync1<=buttons_n;sync2<=sync1;end
 for(genvar i=0;i<4;i=i+1) begin:g_button
  always_ff @(posedge clk or negedge rst_n)
   if (!rst_n) begin stable_n[i]<=1'b1;count[i]<='0;press[i]<=1'b0;end
   else begin
    press[i]<=1'b0;
    if(sync2[i]==stable_n[i]) count[i]<='0;
    else if(count[i]==DEBOUNCE_CYCLES-1) begin
     count[i]<='0;stable_n[i]<=sync2[i];press[i]<=!sync2[i];
    end else count[i]<=count[i]+1'b1;
   end
 end
 always_comb begin
  command_valid=|press;command_data=8'h30;
  if(press[3]) command_data=8'h30;
  else if(press[2]) command_data=8'h33;
  else if(press[1]) command_data=8'h30+{5'd0,(stage+3'd1)};
  else if(press[0]) command_data=8'h30+{5'd0,(stage-3'd1)};
 end
endmodule
