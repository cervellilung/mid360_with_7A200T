// RGB565 -> DVI-compatible video on board HDMI port; no audio/HDCP/EDID.
// Encode latency is 3 pixel clocks; four OSERDES lanes serialize LSB first.
`timescale 1ns/1ps
module acx750_hdmi_tx(input wire pixel_clk,serial_clk,rst_n,
 input wire [15:0] rgb565,input wire hs,vs,de,
 output wire hdmi_clk_p,hdmi_clk_n,output wire [2:0] hdmi_dat_p,hdmi_dat_n);
 wire [9:0] symbols[0:3];
 acx750_tmds_encode u_blue(.clk(pixel_clk),.rst_p(!rst_n),
  .din({rgb565[4:0],rgb565[4:2]}),.c0(hs),.c1(vs),.de(de),.dout(symbols[0]));
 acx750_tmds_encode u_green(.clk(pixel_clk),.rst_p(!rst_n),
  .din({rgb565[10:5],rgb565[10:9]}),.c0(1'b0),.c1(1'b0),.de(de),.dout(symbols[1]));
 acx750_tmds_encode u_red(.clk(pixel_clk),.rst_p(!rst_n),
  .din({rgb565[15:11],rgb565[15:13]}),.c0(1'b0),.c1(1'b0),.de(de),.dout(symbols[2]));
 assign symbols[3]=10'b1111100000;
 wire [3:0] p,n;
 for(genvar i=0;i<4;i=i+1) begin:g_lane
  wire shift1,shift2,oq;
  OSERDESE2 #(.DATA_RATE_OQ("DDR"),.DATA_RATE_TQ("SDR"),.DATA_WIDTH(10),
   .SERDES_MODE("MASTER"),.TRISTATE_WIDTH(1)) u_master(
   .CLK(serial_clk),.CLKDIV(pixel_clk),.RST(!rst_n),.OCE(1'b1),.OQ(oq),.OFB(),
   .D1(symbols[i][0]),.D2(symbols[i][1]),.D3(symbols[i][2]),.D4(symbols[i][3]),
   .D5(symbols[i][4]),.D6(symbols[i][5]),.D7(symbols[i][6]),.D8(symbols[i][7]),
   .SHIFTIN1(shift1),.SHIFTIN2(shift2),.SHIFTOUT1(),.SHIFTOUT2(),
   .T1(1'b0),.T2(1'b0),.T3(1'b0),.T4(1'b0),.TCE(1'b0),.TBYTEIN(1'b0),
   .TBYTEOUT(),.TQ(),.TFB());
  OSERDESE2 #(.DATA_RATE_OQ("DDR"),.DATA_RATE_TQ("SDR"),.DATA_WIDTH(10),
   .SERDES_MODE("SLAVE"),.TRISTATE_WIDTH(1)) u_slave(
   .CLK(serial_clk),.CLKDIV(pixel_clk),.RST(!rst_n),.OCE(1'b1),.OQ(),.OFB(),
   .D1(1'b0),.D2(1'b0),.D3(symbols[i][8]),.D4(symbols[i][9]),
   .D5(1'b0),.D6(1'b0),.D7(1'b0),.D8(1'b0),
   .SHIFTIN1(1'b0),.SHIFTIN2(1'b0),.SHIFTOUT1(shift1),.SHIFTOUT2(shift2),
   .T1(1'b0),.T2(1'b0),.T3(1'b0),.T4(1'b0),.TCE(1'b0),.TBYTEIN(1'b0),
   .TBYTEOUT(),.TQ(),.TFB());
  OBUFDS #(.IOSTANDARD("TMDS_33"),.SLEW("FAST")) u_out(.I(oq),.O(p[i]),.OB(n[i]));
 end
 assign hdmi_dat_p=p[2:0];assign hdmi_dat_n=n[2:0];
 assign hdmi_clk_p=p[3];assign hdmi_clk_n=n[3];
endmodule
