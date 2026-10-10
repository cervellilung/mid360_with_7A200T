// Native: pixel 51.25 MHz, serial 256.25 MHz; fallback: 33.333/166.667 MHz.
// Same MMCM supplies CLK and CLKDIV; exact 5:1 ratio, no frame buffer.
`timescale 1ns/1ps
module acx750_hdmi_clocks #(parameter bit NATIVE_600=1)(input wire clk50m,input wire reset_n,
 output wire pixel_clk,serial_clk,locked);
 wire fb_raw,fb,pixel_raw,serial_raw;
 MMCME2_BASE #(.BANDWIDTH("OPTIMIZED"),.CLKIN1_PERIOD(20.0),
  .DIVCLK_DIVIDE(1),.CLKFBOUT_MULT_F(NATIVE_600?20.5:20.0),
  .CLKOUT0_DIVIDE_F(NATIVE_600?4.0:6.0),.CLKOUT1_DIVIDE(NATIVE_600?20:30),.STARTUP_WAIT("FALSE")) u_mmcm(
  .CLKIN1(clk50m),.CLKFBIN(fb),.CLKFBOUT(fb_raw),.CLKFBOUTB(),
  .CLKOUT0(serial_raw),.CLKOUT0B(),.CLKOUT1(pixel_raw),.CLKOUT1B(),
  .CLKOUT2(),.CLKOUT2B(),.CLKOUT3(),.CLKOUT3B(),.CLKOUT4(),.CLKOUT5(),.CLKOUT6(),
  .LOCKED(locked),.PWRDWN(1'b0),.RST(!reset_n));
 BUFG u_fb(.I(fb_raw),.O(fb));
 BUFG u_pixel(.I(pixel_raw),.O(pixel_clk));
 BUFG u_serial(.I(serial_raw),.O(serial_clk));
endmodule
