`timescale 1ns/1ps
module tb_write_bridge;
  reg sys=0,pix=0,eth=0,cam=0;
  always #5 sys=~sys;
  always #10 pix=~pix;
  always #4 eth=~eth;
  always #7 cam=~cam;
  reg rst=0,flush=1,block_read=0;
  reg [2:0] stage=1;
  reg pv=0,ev=0,cv=0;
  reg [15:0] pd=0,ed=0,cd=0;
  wire valid; wire [15:0] data; wire [2:0] overflow;
  reg [7:0] cycles=0;
  wire ready = !block_read && cycles[1:0] != 0;
  integer got=0, base=0;
  acx750_write_bridge #(.DEPTH(128)) dut(
    .sys_clk(sys),.rst_n(rst),.flush(flush),.stage(stage),
    .pix_clk(pix),.pix_valid(pv),.pix_data(pd),
    .eth_clk(eth),.eth_valid(ev),.eth_data(ed),
    .cam_clk(cam),.cam_valid(cv),.cam_data(cd),
    .out_ready(ready),.out_valid(valid),.out_data(data),.overflow(overflow));
  always @(posedge sys) begin
    cycles <= cycles+1;
    if (rst && !flush && valid && ready) begin
      if (data !== base+got) $fatal(1,"ORDER stage=%0d got=%0d data=%0d expected=%0d",stage,got,data,base+got);
      got=got+1;
    end
  end
  task select_lane(input integer lane,input integer value);
    @(negedge sys);flush=1;stage=lane;got=0;base=value;
    #400;@(negedge sys);flush=0;#500;
  endtask
  task send(input integer lane,input integer count);
    integer i;
    for(i=0;i<count;i=i+1) begin
      case(lane)
        1: begin @(negedge pix);pd=base+i;pv=1;end
        2: begin @(negedge eth);ed=base+i;ev=1;end
        3: begin @(negedge cam);cd=base+i;cv=1;end
      endcase
    end
    case(lane)
      1: begin @(negedge pix);pv=0;end
      2: begin @(negedge eth);ev=0;end
      3: begin @(negedge cam);cv=0;end
    endcase
  endtask
  initial begin
    #100;rst=1;
    select_lane(1,1000);send(1,80);wait(got==80);#200;
    if (overflow) $fatal(1,"Unexpected overflow");
    select_lane(2,2000);send(2,80);wait(got==80);#200;
    select_lane(3,3000);send(3,80);wait(got==80);#200;
    block_read=1;select_lane(2,4000);send(2,160);#300;
    if (!overflow[1]) $fatal(1,"Missing full FIFO loss indication");
    // Flush a nonempty lane. No old word may emerge after stage switch.
    select_lane(1,5000);block_read=0;send(1,40);wait(got==40);#200;
    if (overflow) $fatal(1,"Flush did not clear overflow");
    // Reset with queued data; no pre-reset item may reappear.
    block_read=1;send(1,20);#100;rst=0;#200;rst=1;
    select_lane(3,6000);block_read=0;send(3,40);wait(got==40);#200;
    $display("WRITE_BRIDGE_PASS: clocks/order/backpressure/overflow/flush/reset");$finish;
  end
  initial begin #100000;$fatal(1,"TIMEOUT got=%0d",got);end
endmodule
