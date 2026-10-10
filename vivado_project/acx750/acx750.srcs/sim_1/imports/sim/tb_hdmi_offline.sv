`timescale 1ns/1ps
module tb_hdmi_offline;
 reg clk=0,serial=0,rst_n=0,raster_phase=0;
 always #10 clk=~clk;
 always #2 if(!raster_phase) serial=~serial;
 reg [3:0] buttons=15;reg [2:0] stage=0;
 wire cmd;wire [7:0] command;
 acx750_buttons #(.DEBOUNCE_CYCLES(4)) b(clk,rst_n,buttons,stage,cmd,command);
 integer events=0;reg [7:0] last_command;
 always @(posedge clk) if(cmd) begin events=events+1;last_command=command;end
 wire req,sof,hs,vs,de;wire [15:0] rgb;
 wire req0,de0;wire [15:0] rgb0;
 wire old_req,old_de;wire [15:0] old_rgb;
 acx750_hdmi_canvas c(.ClkDisp(clk),.Rst_n(rst_n),.Data(16'hffff),
 .DataReq(req),.Disp_Sof(sof),.Disp_HS(hs),.Disp_VS(vs),.Disp_DE(de),
 .H_Addr(),.V_Addr(),.Disp_Red(rgb[15:11]),.Disp_Green(rgb[10:5]),.Disp_Blue(rgb[4:0]),.Disp_PCLK());
 acx750_hdmi_canvas #(.NATIVE_600(0)) c0(.ClkDisp(clk),.Rst_n(rst_n),.Data(16'hffff),
 .DataReq(req0),.Disp_Sof(),.Disp_HS(),.Disp_VS(),.Disp_DE(de0),
 .H_Addr(),.V_Addr(),.Disp_Red(rgb0[15:11]),.Disp_Green(rgb0[10:5]),.Disp_Blue(rgb0[4:0]),.Disp_PCLK());
 disp_driver #(.AHEAD_CLK_CNT(2)) old(.ClkDisp(clk),.Rst_n(rst_n),.Data(16'hffff),
 .DataReq(old_req),.Disp_Sof(),.Disp_HS(),.Disp_VS(),.Disp_DE(old_de),
 .H_Addr(),.V_Addr(),.Disp_Red(old_rgb[15:11]),.Disp_Green(old_rgb[10:5]),.Disp_Blue(old_rgb[4:0]),.Disp_PCLK());
 reg txhs=0,txvs=0;wire cp,cn;wire [2:0] dp,dn;
 acx750_hdmi_tx tx(.pixel_clk(clk),.serial_clk(serial),.rst_n(rst_n && !raster_phase),
 .rgb565(16'hffff),.hs(txhs),.vs(txvs),.de(1'b0),
 .hdmi_clk_p(cp),.hdmi_clk_n(cn),.hdmi_dat_p(dp),.hdmi_dat_n(dn));
 reg clk50=0;always #10 if(!raster_phase) clk50=~clk50;
 wire pclk,sclk,locked;
 acx750_hdmi_clocks clocks(.clk50m(clk50),.reset_n(rst_n && !raster_phase),.pixel_clk(pclk),.serial_clk(sclk),.locked(locked));
 integer pc=0,sc=0;
 always @(posedge pclk) if(locked) pc=pc+1;
 always @(posedge sclk) if(locked) sc=sc+1;
 task press(input [3:0] value,input [7:0] expected);
 integer before_count;
 begin
 before_count=events;@(negedge clk);buttons=value;repeat(30) @(negedge clk);
 if(events!=before_count+1 || last_command!==expected) $fatal(1,"FAIL button %h count %d command %h",value,events,last_command);
 repeat(30) @(negedge clk);if(events!=before_count+1) $fatal(1,"FAIL held button repeats");
 buttons=15;repeat(15) @(negedge clk);
 end endtask
 integer i,nd=0,nr=0,np=0,fd=0,fr=0;
 reg [9:0] ctl;reg [9:0] sample_word;integer k,j,match_count;
 initial begin
 repeat(6) @(negedge clk);rst_n=1;repeat(8) @(negedge clk);
 buttons=14;repeat(2) @(negedge clk);buttons=15;repeat(15) @(negedge clk);
 if(events!=0) $fatal(1,"FAIL bounce");
 stage=0;press(14,8'h37);stage=7;press(13,8'h30);
 press(11,8'h33);press(7,8'h30);press(0,8'h30);
 for(k=0;k<4;k=k+1) begin
 @(negedge clk);{txvs,txhs}=k;repeat(15) @(negedge clk);
 case(k) 0:ctl=10'b1101010100;1:ctl=10'b0010101011;2:ctl=10'b0101010100;3:ctl=10'b1010101011;endcase
 if(tx.symbols[0]!==ctl || tx.symbols[1]!==10'b1101010100 || tx.symbols[2]!==10'b1101010100) $fatal(1,"FAIL control code");
 sample_word=0;
 for(j=0;j<10;j=j+1) begin @(serial);#0.2;sample_word[j]=dp[0];if(dp!==~dn || cp!==~cn) $fatal(1,"FAIL differential outputs");end
 match_count=0;for(j=0;j<10;j=j+1) if(sample_word==((ctl>>j)|(ctl<<(10-j)))) match_count=match_count+1;
 if(match_count==0) $fatal(1,"FAIL serialized control bits %b expected rotation %b",sample_word,ctl);
 end
 repeat(2000) @(negedge clk);
 if(!locked || pc<100 || sc<pc*5-6 || sc>pc*5+6) $fatal(1,"FAIL MMCM lock/ratio %d/%d",sc,pc);
 $display("CHECK buttons debounce/wrap/priority; TMDS controls/serialization; MMCM 5:1 PASS");
 raster_phase=1;rst_n=0;repeat(6) @(negedge clk);rst_n=1;
 for(i=0;i<1344*628+2;i=i+1) begin
 @(posedge clk);#2;
 if(de) nd=nd+1;if(req) nr=nr+1;if(rgb==16'hffff) np=np+1;
 if(i<1056*525+2) begin if(de0) fd=fd+1;if(req0) fr=fr+1;end
 if(i>2 && (req0!==old_req || de0!==old_de || rgb0!==old_rgb)) $fatal(1,"FAIL fallback source compatibility cycle %d",i);
 if(!de && rgb!=0) $fatal(1,"FAIL outside DE");
 end
 if(nd!=614400 || nr!=384000 || np!=384000 || fd!=384000 || fr!=384000) $fatal(1,"FAIL raster counts %d %d %d %d %d",nd,nr,np,fd,fr);
 $display("CHECK native DE=614400, centered pixels/requests=384000; fallback cycle agreement PASS");
 $display("PASS tb_hdmi_offline");$finish;
 end
 initial begin #20000000;$fatal(1,"FAIL timeout");end
endmodule
