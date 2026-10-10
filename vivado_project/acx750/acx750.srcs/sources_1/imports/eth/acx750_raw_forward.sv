`timescale 1ns/1ps
// Four bounded packet slots. Payload storage is synchronous dual-port BRAM.
// Release only after the shared UDP engine has drained its FCS.
module acx750_raw_forward (
 input logic clk, rst_n,
 input logic rx_valid, input logic [7:0] rx_data,
 input logic rx_done, rx_error, input logic [15:0] rx_length,
 input logic [31:0] rx_source_ip, input logic [15:0] rx_source_port,
 input logic telemetry_start, input logic [15:0] telemetry_length,
 input logic [7:0] telemetry_data, output logic telemetry_req,
 output logic udp_start, output logic [15:0] udp_length, udp_port,
 output logic [7:0] udp_data, input logic udp_req, udp_busy,
 output logic [31:0] accepted, dropped, forwarded
);
 (* ram_style="block" *) logic [7:0] mem [0:8191];
 logic [15:0] lengths [0:3];
 logic [1:0] head, tail;
 logic [2:0] used;
 logic [11:0] wcount;
 logic capture_drop;
 logic [6:0] idle_cycles;
 logic [10:0] rd_index;
 logic [7:0] rd_data;
 logic tele_pending;
 logic [15:0] tele_length;
 logic active, owner_raw, seen_busy;
 wire full = (used == 3'd4);
 wire source_ok = (rx_source_ip == 32'hc0a80114 && rx_source_port == 16'd56300);
 wire commit = rx_done && !rx_error && !capture_drop && wcount != 0 &&
               wcount <= 12'd1472 && wcount == rx_length && source_ok;
 wire release_raw = active && owner_raw && seen_busy && !udp_busy;
 wire read_advance = active && owner_raw && udp_req;
 wire [10:0] read_next = read_advance ? rd_index + 11'd1 : rd_index;
 // Separate clocked read/write ports; memory and length table have no reset.
 always_ff @(posedge clk) begin
   if (rx_valid && wcount < 2048 && !capture_drop && !(wcount == 0 && full))
     mem[{tail,wcount[10:0]}] <= rx_data;
   rd_data <= mem[{head,read_next}];
   if (commit) lengths[tail] <= rx_length;
 end
 assign udp_data = owner_raw ? rd_data : telemetry_data;
 assign telemetry_req = active && !owner_raw && udp_req;
 always_ff @(posedge clk or negedge rst_n) begin
   if (!rst_n) begin
     head<=0;tail<=0;used<=0;wcount<=0;capture_drop<=0;idle_cycles<=0;
     rd_index<=0;tele_pending<=0;tele_length<=0;
     active<=0;owner_raw<=0;seen_busy<=0;udp_start<=0;udp_length<=0;udp_port<=0;
     accepted<=0;dropped<=0;forwarded<=0;
   end else begin
     udp_start<=0;
     if (telemetry_start) begin tele_pending<=1;tele_length<=telemetry_length;end
     if (rx_valid) begin
       idle_cycles<=0;
       if (wcount == 0) capture_drop<=full;
       if (wcount < 2049) wcount<=wcount+1'b1;
     end else if(idle_cycles < 127) idle_cycles<=idle_cycles+1'b1;
     if(rx_done) begin
       wcount<=0;capture_drop<=0;
       if(commit) begin tail<=tail+1'b1;accepted<=accepted+1'b1;end
       else if(wcount != 0) dropped<=dropped+1'b1;
     end else if(!rx_valid && idle_cycles == 63 && wcount != 0) begin
       // Aborted/truncated input must not contaminate the next packet.
       wcount<=0;capture_drop<=0;dropped<=dropped+1'b1;
     end
     case ({commit,release_raw})
       2'b10:used<=used+1'b1;
       2'b01:used<=used-1'b1;
       default:used<=used;
     endcase
     if (!active) begin
       seen_busy<=0;rd_index<=0;
       // Telemetry cannot starve behind sustained radar traffic.
       if (tele_pending || telemetry_start) begin
         active<=1;owner_raw<=0;udp_start<=1;
         udp_length<=telemetry_start ? telemetry_length : tele_length;
         udp_port<=16'd46000;tele_pending<=0;
       end else if(used != 0) begin
         active<=1;owner_raw<=1;udp_start<=1;
         udp_length<=lengths[head];udp_port<=16'd46110;
       end
     end else begin
       if (udp_busy) seen_busy<=1;
       if (read_advance) rd_index<=rd_index+1'b1;
       if (seen_busy && !udp_busy) begin
         active<=0;
         if(owner_raw) begin head<=head+1'b1;forwarded<=forwarded+1'b1;end
       end
     end
   end
 end
endmodule
