// HDMI canvas; request only the centered 800x480 source, without scaling.
// Native timing follows the vendor Resolution_1024x600 table (1344x628).
`timescale 1ns/1ps
module acx750_hdmi_canvas #(
 parameter bit NATIVE_600=1,
 parameter integer AHEAD_CLK_CNT=2
)(input wire ClkDisp,Rst_n,input wire [15:0] Data,
 output logic DataReq,Disp_Sof,Disp_HS,Disp_VS,Disp_DE,
 output wire [11:0] H_Addr,V_Addr,
 output logic [4:0] Disp_Red,Disp_Blue,output logic [5:0] Disp_Green,
 output wire Disp_PCLK);
 localparam integer HT=NATIVE_600?1344:1056;
 localparam integer VT=NATIVE_600?628:525;
 localparam integer HS=NATIVE_600?136:128;
 localparam integer VS=NATIVE_600?4:2;
 localparam integer HB=NATIVE_600?295:215;
 localparam integer VB=NATIVE_600?26:34;
 localparam integer DW=NATIVE_600?1024:800;
 localparam integer DH=NATIVE_600?600:480;
 localparam integer XB=HB+(DW-800)/2;
 localparam integer YB=VB+(DH-480)/2;
 logic [11:0] hcount,vcount;
 logic de_pre,window_pre,req_pre,hs_pre,vs_pre,vs_d;
 assign Disp_PCLK=ClkDisp;
 assign H_Addr=(hcount>=XB && hcount<XB+800)?hcount-XB:12'd0;
 assign V_Addr=(vcount>=YB && vcount<YB+480)?vcount-YB:12'd0;
 always_ff @(posedge ClkDisp or negedge Rst_n) begin
  if(!Rst_n) begin hcount<=0;vcount<=0;end
  else if(hcount==HT-1) begin
   hcount<=0;vcount<=(vcount==VT-1)?12'd0:vcount+1'b1;
  end else hcount<=hcount+1'b1;
 end
 // Synchronous control reset prevents asynchronous BRAM read-enable changes.
 // Preserve the original two-register request pipeline and advance setting.
 always_ff @(posedge ClkDisp) begin
  if(!Rst_n) begin
   de_pre<=0;window_pre<=0;req_pre<=0;hs_pre<=0;vs_pre<=0;
   DataReq<=0;Disp_DE<=0;Disp_HS<=0;Disp_VS<=0;
   Disp_Red<=0;Disp_Green<=0;Disp_Blue<=0;vs_d<=0;Disp_Sof<=0;
  end else begin
   de_pre<=(hcount>=HB && hcount<HB+DW && vcount>=VB && vcount<VB+DH);
   window_pre<=(hcount>=XB && hcount<XB+800 && vcount>=YB && vcount<YB+480);
   req_pre<=(hcount>=XB-AHEAD_CLK_CNT && hcount<XB+800-AHEAD_CLK_CNT && vcount>=YB && vcount<YB+480);
   hs_pre<=hcount>=HS;vs_pre<=vcount>=VS;
   DataReq<=req_pre;Disp_DE<=de_pre;Disp_HS<=hs_pre;Disp_VS<=vs_pre;
   {Disp_Red,Disp_Green,Disp_Blue}<=window_pre?Data:16'd0;
   vs_d<=Disp_VS;Disp_Sof<=!vs_d && Disp_VS;
  end
 end
endmodule
