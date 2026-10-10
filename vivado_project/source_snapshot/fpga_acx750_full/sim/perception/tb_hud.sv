//============================================================================
// 来源：fpga_ac880/sensor_perception_ar/tests/tb_hud.sv，仅调整路径。
// 说明：从 7020（XC7Z020）工程原样搬入 ACX750 新工程，被测逻辑零改动。
//       本文件本身不含任何文件路径。
//============================================================================
`timescale 1ns/1ps
module tb_hud;
 logic cc=0,vc=0,rst=1;always #5 cc=~cc;always #3 vc=~vc;
 logic publish=0,pready,sv=0,sr,sof=0,eol=0,mv,mf,me,mr=1;logic[15:0] md;
 integer sent=0,received=0,x,y;logic [15:0] expected[0:9599];
 logic [31:0] random_state=32'h819237;
 ar_video #(.BOXES(1),.VIDEO_HZ(1000000)) dut(
 .control_clk(cc),.control_rst(rst),.publish(publish),.publish_ready(pready),
 .boxes(1'b0),.bx0(11'd0),.bx1(11'd0),.by0(10'd0),.by1(10'd0),.shifts(6'd0),
 .stereo(1'b0),.test_mode(1'b1),.radar_age_us(32'd0),.motion_age_us(32'd0),
 .nearest_mm(32'd1300),.speed_mm_s(32'hffffffff),.travel_mm(32'hffffffff),.motion_valid(1'b1),.risk(2'd2),
 .clk(vc),.rst(rst),.s_data(16'h1234),.s_valid(sv),.s_sof(sof),.s_eol(eol),.s_ready(sr),
 .m_data(md),.m_valid(mv),.m_sof(mf),.m_eol(me),.m_ready(mr));
 function automatic [34:0] bitmap(input integer c);
 case(c)
  0:bitmap=35'b11110_10001_10001_10001_10001_10001_11110;
  1,21:bitmap=35'b00000_00100_00100_00000_00100_00100_00000;
  3:bitmap=35'b00100_01100_00100_00100_00100_00100_01110;
  4:bitmap=35'b00000_00000_00000_00000_00000_00110_00110;
  5:bitmap=35'b11110_00001_00001_01110_00001_00001_11110;
  6,7:bitmap=35'b01110_10001_10011_10101_11001_10001_01110;
  8:bitmap=35'b10001_11011_10101_10101_10001_10001_10001;
  20:bitmap=35'b11110_10001_10001_11110_10100_10010_10001;
  22:bitmap=35'b01110_10001_00001_00010_00100_01000_11111;
  25,28:bitmap=35'b11111_00100_00100_00100_00100_00100_00100;
  26:bitmap=35'b11111_10000_10000_11110_10000_10000_11111;
  27:bitmap=35'b01111_10000_10000_01110_00001_00001_11110;
  default:bitmap=0;
 endcase
 endfunction
 function automatic [15:0] wanted(input integer xx,yy);
 integer c,row,col;logic[34:0] bits;
 begin
  wanted=16'h1234;
  if(xx>=8&&yy>=8&&yy<22)begin
   c=(xx-8)/12;col=((xx-8)%12)/2;row=(yy-8)/2;bits=bitmap(c);
   if(col<5&&bits[34-row*5-col])wanted=16'hffff;
  end
 end endfunction
 always @(negedge vc)if(!rst)begin random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};mr=random_state[0]|random_state[2];end
 always @(posedge vc)if(!rst&&mv&&mr)begin
  if(received>=sent||md!==expected[received]||mf!==(received==0)||me!==((received%400)==399))$fatal(1,"HUD pixel mismatch %d",received);
  received=received+1;
 end
 initial begin
  #35;rst=0;@(negedge cc);publish=1;@(negedge cc);publish=0;repeat(45)@(posedge cc);
  for(y=0;y<24;y=y+1)for(x=0;x<400;x=x+1)begin
   @(negedge vc);sv=1;sof=x==0&&y==0;eol=x==399;expected[sent]=wanted(x,y);sent=sent+1;
   @(posedge vc);while(!sr)@(posedge vc);@(negedge vc);sv=0;
  end
  wait(received==sent);$display("PASS compact HUD exact pixels, independent clocks, random backpressure, no speed/mileage text");$finish;
 end
 initial begin #2000000;$fatal(1,"HUD timeout");end
endmodule