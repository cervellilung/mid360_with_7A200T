`timescale 1ns/1ps
module tb_hdmi_cdc;
 reg src_clk=0,dest_clk=0,src_rst_n=0,dest_rst_n=0,run_dest=1,stress=1;
 reg [31:0] value=0;wire [31:0] q;
 always #5 src_clk=~src_clk;
 always #9.756 if(run_dest) dest_clk=~dest_clk;
 acx750_cdc_snapshot #(.WIDTH(32)) dut(src_clk,src_rst_n,value,dest_clk,dest_rst_n,q);
 always @(negedge src_clk) if(src_rst_n && stress) value=(value==32'haaaa5555)?32'h5555aaaa:32'haaaa5555;
 integer received=0;
 always @(negedge dest_clk) if(dest_rst_n && stress) begin
  if(q!==32'd0 && q!==32'haaaa5555 && q!==32'h5555aaaa) $fatal(1,"FAIL torn bus %h",q);
  if(q!=0) received=received+1;
 end
 initial begin
 #100;src_rst_n=1;dest_rst_n=1;
 #10000;if(received<20) $fatal(1,"FAIL no coherent updates");
 stress=0;@(negedge src_clk);value=32'h12345678;#2000;
 if(q!==value) $fatal(1,"FAIL stable value");
 run_dest=0;@(negedge src_clk);value=32'h87654321;#1000;run_dest=1;#2000;
 if(q!==value) $fatal(1,"FAIL stopped destination recovery");
 src_rst_n=0;dest_rst_n=0;#100;value=32'h10203040;src_rst_n=1;dest_rst_n=1;#2000;
 if(q!==value) $fatal(1,"FAIL reset recovery");
 $display("PASS tb_hdmi_cdc coherent/stalled-clock/reset");$finish;
 end
 initial begin #50000;$fatal(1,"FAIL timeout");end
endmodule
