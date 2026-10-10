// ============================================================================
// 本文件从 fpga_ac880/sensor_perception_ar/rtl/ar_video.sv 原样搬入，行为未改。
// 原文件名：ar_video.sv
// 原路径：fpga_ac880/sensor_perception_ar/rtl/ar_video.sv
// ============================================================================
`timescale 1ns/1ps
module ar_video #(parameter BOXES=32,parameter VIDEO_HZ=200000000,parameter COMPACT_HUD=1)(
 input logic control_clk,control_rst,publish,output logic publish_ready,
 input logic [BOXES-1:0] boxes,
 input logic [BOXES*11-1:0] bx0,bx1,input logic [BOXES*10-1:0] by0,by1,
 input logic [BOXES*6-1:0] shifts,input logic stereo,test_mode,
 input logic [31:0] radar_age_us,motion_age_us,nearest_mm,speed_mm_s,travel_mm,
 input logic motion_valid,input logic [1:0] risk,
 input logic clk,rst,input logic [15:0] s_data,input logic s_valid,s_sof,s_eol,
 output logic s_ready,output logic [15:0] m_data,output logic m_valid,m_sof,m_eol,
 input logic m_ready);
 localparam PREFIX_W=BOXES*(1+22+20+6)+69;
 localparam BW=PREFIX_W+(COMPACT_HUD?20:60);
 logic [PREFIX_W-1:0] prefix;
 logic calc_busy;logic [5:0] calc_count;
 logic [31:0] near_binary,speed_binary,travel_binary;
 logic [19:0] near_bcd,speed_bcd,travel_bcd;
 function automatic [19:0] bcd_shift(input [19:0] bcd,input logic bit_in);
  logic [19:0] adjusted;integer d;
  begin
   adjusted=bcd;
   for(d=0;d<5;d=d+1)if(bcd[d*4+:4]>=5)adjusted[d*4+:4]=bcd[d*4+:4]+4'd3;
   bcd_shift={adjusted[18:0],bit_in};
  end
 endfunction
 logic [BW-1:0] holding,active;
 logic req,ack;
 (* ASYNC_REG="TRUE" *) logic [2:0] req_sync,ack_sync;
 logic [31:0] age,motion_age,pending_age;
 logic [10:0] x;logic [9:0] y;
 wire [10:0] px=s_sof?0:x;wire [9:0] py=s_sof?0:y;
 wire take=s_valid&&s_ready;
 wire swap=take&&s_sof&&(req_sync[2]!=ack);
 wire [BW-1:0] render=swap?holding:active;
 wire [BOXES-1:0] v;
 wire [BOXES*11-1:0] x0,x1;wire [BOXES*10-1:0] y0,y1;wire [BOXES*6-1:0] disp;
 wire st,tm,mv;wire [1:0] rk;
 wire [31:0] initial_age,initial_motion_age;wire [19:0] near_value,speed,travel;
 generate if(COMPACT_HUD)begin
  assign {v,x0,x1,y0,y1,disp,st,tm,mv,rk,initial_age,initial_motion_age,near_value}=render;
  assign speed=0;assign travel=0;
 end else begin
  assign {v,x0,x1,y0,y1,disp,st,tm,mv,rk,initial_age,initial_motion_age,near_value,speed,travel}=render;
 end endgenerate
 // 3 one-bit flags + risk=5; BW is computed below through explicit padding.
 wire [63:0] next_age=initial_age*64'(VIDEO_HZ/1000000)+pending_age;
 wire [63:0] next_motion_age=initial_motion_age*64'(VIDEO_HZ/1000000)+pending_age;
 wire live=swap?(next_age<(VIDEO_HZ/1000)*150):age<(VIDEO_HZ/1000)*150;
 wire motion_live=mv&&(swap?(next_motion_age<VIDEO_HZ):motion_age<VIDEO_HZ);
 logic red_hit,cyan_hit,plain_hit,hud_hit;logic [15:0] colour;
 integer i;
 logic signed [12:0] shift,left,right,top,bottom,plain_x,red_x,cyan_x;logic y_edge;
 logic [7:0] character;logic [3:0] column;logic [8:0] fontrow;
 wire [10:0] hud_x=px>=8?px-11'd8:11'd0;
 wire [9:0] hud_y=py>=8?py-10'd8:10'd0;
 logic [7:0] ch;logic [4:0] glyph;
 function automatic logic box_edge(input logic signed [12:0] xx,yy,l,t,r,b);
  box_edge=l<=r&&t<=b&&xx>=l&&xx<=r&&yy>=t&&yy<=b&&
   (xx-l<2||r-xx<2||yy-t<2||b-yy<2);
 endfunction
 function automatic [34:0] font(input [7:0] a);
  case(a)
   "0":font=35'b01110_10001_10011_10101_11001_10001_01110;
   "1":font=35'b00100_01100_00100_00100_00100_00100_01110;
   "2":font=35'b01110_10001_00001_00010_00100_01000_11111;
   "3":font=35'b11110_00001_00001_01110_00001_00001_11110;
   "4":font=35'b00010_00110_01010_10010_11111_00010_00010;
   "5":font=35'b11111_10000_10000_11110_00001_00001_11110;
   "6":font=35'b01110_10000_10000_11110_10001_10001_01110;
   "7":font=35'b11111_00001_00010_00100_01000_01000_01000;
   "8":font=35'b01110_10001_10001_01110_10001_10001_01110;
   "9":font=35'b01110_10001_10001_01111_00001_00001_01110;
   "D":font=35'b11110_10001_10001_10001_10001_10001_11110;
   "V":font=35'b10001_10001_10001_10001_10001_01010_00100;
   "M":font=35'b10001_11011_10101_10101_10001_10001_10001;
   "R":font=35'b11110_10001_10001_11110_10100_10010_10001;
   "T":font=35'b11111_00100_00100_00100_00100_00100_00100;
   "E":font=35'b11111_10000_10000_11110_10000_10000_11111;
   "S":font=35'b01111_10000_10000_01110_00001_00001_11110;
   "-":font=35'b00000_00000_00000_11111_00000_00000_00000;
   ".":font=35'b00000_00000_00000_00000_00000_00110_00110;
   ":":font=35'b00000_00100_00100_00000_00100_00100_00000;
   default:font=0;
  endcase
 endfunction
 function automatic [7:0] digit(input [19:0] value,input integer power);
  case(power)
   0:digit="0"+value[3:0];1:digit="0"+value[7:4];
   2:digit="0"+value[11:8];3:digit="0"+value[15:12];
   default:digit="0"+value[19:16];
  endcase
 endfunction
 assign publish_ready=(req==ack_sync[2])&&!calc_busy;
 assign s_ready=!m_valid||m_ready;
 // Convert three HUD values in 32 control cycles; no pixel-clock decimal division.
 // Holding remains stable from request until the video-domain SOF acknowledgement.
 always_ff @(posedge control_clk)begin
  if(control_rst)begin
   req<=0;ack_sync<=0;holding<=0;prefix<=0;calc_busy<=0;calc_count<=0;
   near_binary<=0;speed_binary<=0;travel_binary<=0;near_bcd<=0;speed_bcd<=0;travel_bcd<=0;
  end else begin
   ack_sync<={ack_sync[1:0],ack};
   if(publish&&publish_ready)begin
    prefix<={boxes,bx0,bx1,by0,by1,shifts,stereo,test_mode,motion_valid,risk,
     (radar_age_us == 32'hffffffff ? radar_age_us : radar_age_us+32'd1),
     (motion_age_us == 32'hffffffff ? motion_age_us : motion_age_us+32'd1)};
    near_binary<=nearest_mm;speed_binary<=speed_mm_s;travel_binary<=travel_mm/1000;
    near_bcd<=0;speed_bcd<=0;travel_bcd<=0;calc_count<=0;calc_busy<=1;
   end else if(calc_busy)begin
    near_bcd<=bcd_shift(near_bcd,near_binary[31]);speed_bcd<=bcd_shift(speed_bcd,speed_binary[31]);travel_bcd<=bcd_shift(travel_bcd,travel_binary[31]);
    near_binary<=near_binary<<1;speed_binary<=speed_binary<<1;travel_binary<=travel_binary<<1;
    if(calc_count==31)begin
     if(COMPACT_HUD)holding<={prefix,bcd_shift(near_bcd,near_binary[31])};
     else holding<={prefix,bcd_shift(near_bcd,near_binary[31]),bcd_shift(speed_bcd,speed_binary[31]),bcd_shift(travel_bcd,travel_binary[31])};
     req<=!req;calc_busy<=0;
    end else calc_count<=calc_count+1;
   end
  end
 end
 always_comb begin
  red_hit=0;cyan_hit=0;plain_hit=0;shift=0;left=0;right=0;top=0;bottom=0;
  plain_x=$signed({2'b0,px});red_x=0;cyan_x=0;y_edge=0;
  for(i=0;i<BOXES;i=i+1)begin
   left=$signed({2'b0,x0[i*11+:11]});right=$signed({2'b0,x1[i*11+:11]});
   top=$signed({3'b0,y0[i*10+:10]});bottom=$signed({3'b0,y1[i*10+:10]});shift=$signed({7'b0,disp[i*6+:6]});
   red_x=plain_x+shift;cyan_x=plain_x-shift;
   y_edge=py<top+13'sd2||py>bottom-13'sd2;
   // Share vertical clipping and compare against constant-width borders.
   // Avoid three variable subtractors per edge/eye in the pixel pipeline.
   if(v[i]&&live&&left<=right&&top<=bottom&&py>=top&&py<=bottom)begin
    if(plain_x>=left&&plain_x<=right&&(y_edge||plain_x<left+13'sd2||plain_x>right-13'sd2))plain_hit=1;
    if(red_x>=left&&red_x<=right&&(y_edge||red_x<left+13'sd2||red_x>right-13'sd2))red_hit=1;
    if(cyan_x>=left&&cyan_x<=right&&(y_edge||cyan_x<left+13'sd2||cyan_x>right-13'sd2))cyan_hit=1;
   end
  end
  character=hud_x/11'd12;column=(hud_x%11'd12)>>1;fontrow=hud_y>>1;ch=" ";glyph=0;
  if(character==0)ch="D";else if(character==1)ch=":";
  else if(character>=3&&character<=7)begin
   if(!live||near_value==0)ch="-";
   else ch=character==4?".":digit(near_value,character==3?3:7-character);
  end else if(character==8)ch="M";
  else if(!COMPACT_HUD&&character==10)ch="V";else if(!COMPACT_HUD&&character==11)ch=":";
  else if(!COMPACT_HUD&&character>=13&&character<=17)begin
   if(!motion_live)ch="-";else ch=character==14?".":digit(speed,character==13?3:17-character);
  end else if(character==20)ch="R";else if(character==21)ch=":";
  else if(character==22)ch=live?digit({18'b0,rk},0):"-";
  else if(tm&&character>=25&&character<=28)case(character)25:ch="T";26:ch="E";27:ch="S";28:ch="T";endcase
  else if(!COMPACT_HUD&&character==30)ch="M";else if(!COMPACT_HUD&&character==31)ch=":";
  else if(!COMPACT_HUD&&character>=33&&character<=37)ch=digit(travel,37-character);
  if(fontrow>=0&&fontrow<7)glyph=(font(ch)>>(5*(6-fontrow)));
  hud_hit=px>=8&&py>=8&&py<22&&column>=0&&column<5&&glyph[4-column];
  colour=s_data;
  if(st)begin if(red_hit&&cyan_hit)colour=16'hffff;else if(red_hit)colour=16'hf800;else if(cyan_hit)colour=16'h07ff;end
  else if(plain_hit)colour=rk==2?16'hf800:rk==1?16'hffe0:16'h07e0;
  if(hud_hit)colour=16'hffff;
 end
 always_ff @(posedge clk)begin
  if(rst)begin req_sync<=0;ack<=0;active<=0;x<=0;y<=0;m_valid<=0;m_data<=0;m_sof<=0;m_eol<=0;age<=32'hffffffff;motion_age<=32'hffffffff;pending_age<=0;end
  else begin
   req_sync<={req_sync[1:0],req};
   if(req_sync[2]==ack)pending_age<=0;else if(pending_age!=32'hffffffff)pending_age<=pending_age+1;
   if(age!=32'hffffffff)age<=age+1;
   if(motion_age!=32'hffffffff)motion_age<=motion_age+1;
   if(s_ready)begin
    m_valid<=s_valid;
    if(s_valid)begin
     m_data<=colour;m_sof<=s_sof;m_eol<=s_eol;
     if(s_eol)begin x<=0;y<=s_sof?1:y+1;end
     else if(s_sof)begin x<=1;y<=0;end else x<=x+1;
     if(swap)begin active<=holding;ack<=req_sync[2];age<=next_age>32'hffffffff ?32'hffffffff:next_age[31:0];motion_age<=next_motion_age>32'hffffffff ?32'hffffffff:next_motion_age[31:0];end
    end
   end
  end
 end
endmodule