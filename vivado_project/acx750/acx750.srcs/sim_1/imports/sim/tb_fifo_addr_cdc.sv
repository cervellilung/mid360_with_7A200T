`timescale 1ns/1ps
module tb_fifo_addr_cdc;
 reg wr_clk=0, rd_clk=0, axi_clk=0, reset=1;
 reg wr_clear=0, rd_frame=0, axi_run=1;
 wire wr_clear_axi, rd_frame_axi;
 integer received=0, expected=0, k, before_count;
 reg previous=0;
 always #5 wr_clk=~wr_clk;
 always #9.75609756 rd_clk=~rd_clk;
 always #5 if(axi_run) axi_clk=~axi_clk;
 acx750_fifo_addr_cdc dut(.*);
 always @(posedge axi_clk) begin
   if(reset) previous<=0;
   else begin
     if(rd_frame_axi && previous) $fatal(1,"Frame event wider than one AXI cycle");
     previous<=rd_frame_axi;
     if(rd_frame_axi) received<=received+1;
   end
 end
 task frame;
   begin
     @(negedge rd_clk); rd_frame=1;
     @(negedge rd_clk); rd_frame=0;
     expected=expected+1;
   end
 endtask
 initial begin
   #400; @(negedge axi_clk); reset=0;
   #500;
   if(received!=0) $fatal(1,"Spurious frame on initial reset release");
   @(negedge wr_clk); wr_clear=1;
   #200; if(!wr_clear_axi) $fatal(1,"Held write clear did not arrive");
   @(negedge wr_clk); wr_clear=0;
   #200; if(wr_clear_axi) $fatal(1,"Write clear did not release");
   for(k=0;k<24;k=k+1) begin
     repeat(10+k%13) @(negedge rd_clk);
     frame();
     #200;
     if(received!=expected) $fatal(1,"Missing or repeated frame %0d %0d",received,expected);
   end
   // One pending event must survive a stopped AXI clock.
   @(negedge axi_clk); axi_run=0;
   frame(); #300;
   if(received!=expected-1) $fatal(1,"Stopped destination unexpectedly advanced");
   axi_run=1; #300;
   if(received!=expected) $fatal(1,"Pending frame lost across clock pause");
   // Reset both domains long enough; no invented SOF on recovery.
   before_count=received;
   @(negedge axi_clk); reset=1;
   #400; @(negedge axi_clk); reset=0;
   #500;
   if(received!=before_count) $fatal(1,"Spurious event after reset");
   frame(); #300;
   if(received!=expected) $fatal(1,"Frame lost after reset");
   $display("PASS tb_fifo_addr_cdc level/pulse/clock-pause/reset count=%0d",received);
   $finish;
 end
 initial begin #50000; $fatal(1,"Timeout"); end
endmodule
