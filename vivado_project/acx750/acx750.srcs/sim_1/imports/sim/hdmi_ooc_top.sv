// Synthesis-only local wrapper, not the board top.
`timescale 1ns/1ps
module hdmi_ooc_top(input wire clk50m,reset_n,input wire [15:0] rgb,
 output wire cp,cn,output wire [2:0] dp,dn,output wire req);
 wire pix,serial,locked,pix_rst_n,hs,vs,de;wire [15:0] out_rgb;
 acx750_hdmi_clocks c(clk50m,reset_n,pix,serial,locked);
 acx750_rst_sync rs(.clk(pix),.arst_n(reset_n && locked),.rst_n(pix_rst_n));
 acx750_hdmi_canvas canvas(.ClkDisp(pix),.Rst_n(pix_rst_n),.Data(rgb),
 .DataReq(req),.Disp_Sof(),.Disp_HS(hs),.Disp_VS(vs),.Disp_DE(de),
 .H_Addr(),.V_Addr(),.Disp_Red(out_rgb[15:11]),.Disp_Green(out_rgb[10:5]),.Disp_Blue(out_rgb[4:0]),.Disp_PCLK());
 acx750_hdmi_tx tx(pix,serial,pix_rst_n,out_rgb,hs,vs,de,cp,cn,dp,dn);
endmodule
