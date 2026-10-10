`timescale 1ns/1ps
module tb_n10;
 logic clk=0;always #5 clk=~clk;
 logic rst=1,bv=0;logic [7:0] bd;logic [63:0] now_us=0;
 wire pv,pg,pl;logic ready=1;wire [15:0] angle,dist;wire [7:0] intensity;wire [63:0] stamp;
 wire [31:0] pk,bad,drop;integer got=0;logic [7:0] packet[0:57];integer sum;
 n10_packet_rx dut(clk,rst,bv,bd,now_us,pv,ready,angle,dist,intensity,pg,pl,stamp,pk,bad,drop);
 always @(posedge clk)if(!rst)begin
  now_us<=now_us+1;
  if(pv&&ready)begin
   if(angle!=((35900+(200*got)/15)%36000)||dist!=1000+got||intensity!=got||!pg||pl!=(got==15))$fatal(1,"N10 point mismatch %0d angle %0d",got,angle);
   got=got+1;
  end
 end
 task send_packet;
  for(integer k=0;k<58;k=k+1)begin @(negedge clk);bv=1;bd=packet[k];@(negedge clk);bv=0;end
 endtask
 initial begin
  for(integer k=0;k<58;k=k+1)packet[k]=0;
  packet[0]=8'ha5;packet[1]=8'h5a;packet[2]=58;packet[5]=35900>>8;packet[6]=35900;
  for(integer k=0;k<16;k=k+1)begin packet[7+k*3]=(1000+k)>>8;packet[8+k*3]=1000+k;packet[9+k*3]=k;end
  packet[55]=0;packet[56]=100;sum=0;for(integer k=0;k<57;k=k+1)sum=sum+packet[k];packet[57]=sum;
  repeat(4)@(negedge clk);rst=0;send_packet();
  ready=0;repeat(5)@(negedge clk);ready=1;
  wait(got==16);repeat(4)@(negedge clk);
  if(pk!=1||bad||drop)$fatal(1,"N10 valid packet counters");
  packet[57]=packet[57]^8'h01;send_packet();repeat(5)@(negedge clk);
  if(bad!=1||got!=16)$fatal(1,"N10 bad checksum leaked points");
  @(negedge clk);bv=1;bd=8'ha5;@(negedge clk);bv=0;
  repeat(2005)@(negedge clk);
  if(bad!=2)$fatal(1,"N10 partial packet timeout");
  $display("PASS n10 valid bad checksum timeout wrap backpressure");$finish;
 end
 initial begin #100000;$fatal(1,"Timeout");end
endmodule
