// Eight diagnostic pixels carry provenance through the actual video FIFOs/DDR.
// No added video register, frame store, division, multiplier or large mux.
// Measurement starts at the first decoded RGB565 pixel, not sensor exposure.
`timescale 1ns/1ps
module acx750_latency_stamp(
 input logic clk,rst_n,sof,valid,input logic [47:0] now_us,
 input logic [15:0] pixel,output logic [15:0] stamped
);
 logic armed,active;logic [2:0] index;
 logic [47:0] timestamp;logic [15:0] sequence_id;
 wire first=armed&&valid;
 wire [15:0] checkword=timestamp[15:0]^{timestamp[26:16],timestamp[31:27]}^timestamp[47:32]^sequence_id^16'h6d2b;
 always_comb begin
  stamped=pixel;
  if(first)stamped=16'hc39a;
  else if(active)case(index)
   1:stamped=16'h5e71;2:stamped=timestamp[15:0];
   3:stamped=timestamp[31:16];4:stamped=sequence_id;
   5:stamped=timestamp[47:32];6:stamped=checkword;7:stamped=16'hd5e3;
   default:stamped=pixel;
  endcase
 end
 always_ff @(posedge clk)begin
  if(!rst_n)begin armed<=0;active<=0;index<=0;sequence_id<=0;end
  else if(sof)begin armed<=1;active<=0;index<=0;end
  else if(valid)begin
   if(armed)begin timestamp<=now_us;sequence_id<=sequence_id+1'b1;armed<=0;active<=1;index<=1;end
   else if(active)begin if(index==7)active<=0;else index<=index+1'b1;end
  end
 end
endmodule

module acx750_latency_probe #(parameter integer MAX_US=999999)(
 input logic clk,rst_n,enable,valid,input logic [47:0] now_us,
 input logic [15:0] pixel,input logic extra_us,
 output wire [15:0] clean,output logic sample,
 output logic [31:0] latency_us,captured_us,output logic [15:0] frame_id,
 output logic [31:0] bad_tags
);
 logic [2:0] index;logic [47:0] timestamp,output_time;
 logic [15:0] sequence_id,checksum;
 wire first=enable&&valid&&index==0&&pixel==16'hc39a;
 wire [47:0] elapsed=output_time-timestamp;
 wire [15:0] expected=timestamp[15:0]^{timestamp[26:16],timestamp[31:27]}^timestamp[47:32]^sequence_id^16'h6d2b;
 // Reserved tag pixels are blacked out before any AR overlay, without delay.
 assign clean=enable&&(index!=0||first)?16'd0:pixel;
 always_ff @(posedge clk)begin
  if(!rst_n)begin index<=0;sample<=0;bad_tags<=0;end
  else begin
   sample<=0;
   if(!enable)index<=0;
   else if(valid)begin
    case(index)
     0:if(first)begin index<=1;output_time<=now_us+extra_us;end
     1:if(pixel==16'h5e71)index<=2;else begin index<=0;bad_tags<=bad_tags+1'b1;end
     2:begin timestamp[15:0]<=pixel;index<=3;end
     3:begin timestamp[31:16]<=pixel;index<=4;end
     4:begin sequence_id<=pixel;index<=5;end
     5:begin timestamp[47:32]<=pixel;index<=6;end
     6:begin checksum<=pixel;index<=7;end
     7:begin
      index<=0;
      if(pixel==16'hd5e3&&checksum==expected&&elapsed<=MAX_US)begin
       latency_us<=elapsed[31:0];captured_us<=timestamp[31:0];frame_id<=sequence_id;sample<=1;
      end else bad_tags<=bad_tags+1'b1;
     end
    endcase
   end
  end
 end
endmodule

module acx750_latency_bcd #(parameter integer STALE_US=250000)(
 input logic clk,rst_n,enable,sample,input logic [31:0] now_us,value_us,sample_age_us,
 output logic [23:0] bcd,output wire valid,output wire busy
);
 logic converting,have_value;logic [4:0] count;
 logic [19:0] binary;logic [23:0] work,adjusted;
 logic [31:0] last_sample;
 assign valid=enable&&have_value&&(now_us-last_sample<STALE_US);
 assign busy=converting;
 // Same serial double-dabble method as the existing AR control-domain HUD.
 // Six independent 4-bit adjustments, then a fixed 1-bit shift; 20 cycles.
 always_comb begin
  adjusted=work;
  for(int i=0;i<6;i++)if(work[i*4+:4]>=5)adjusted[i*4+:4]=work[i*4+:4]+4'd3;
 end
 always_ff @(posedge clk)begin
  if(!rst_n||!enable)begin converting<=0;have_value<=0;count<=0;end
  else if(!converting&&have_value&&now_us-last_sample>=STALE_US&&!sample)have_value<=0;
  else if(sample&&!converting)begin
   // Freshness follows capture time, NOT reception. Repeated old DDR frames
   // and queued metadata must not extend a stopped camera's validity.
   if(value_us<=999999&&sample_age_us<STALE_US)begin binary<=value_us[19:0];work<=0;count<=0;converting<=1;last_sample<=now_us-sample_age_us;end
   else have_value<=0;
  end else if(converting)begin
   work<={adjusted[22:0],binary[19]};binary<={binary[18:0],1'b0};
   if(count==19)begin bcd<={adjusted[22:0],binary[19]};converting<=0;have_value<=1;end
   else count<=count+1'b1;
  end
 end
endmodule

module acx750_video_latency #(parameter integer CLK_HZ=100000000,STALE_US=250000)(
 input logic sys_clk,sys_rst_n,sys_enable,
 input logic cam_clk,cam_rst_n,cam_sof,cam_valid,input logic [15:0] cam_pixel,
 output wire [15:0] cam_stamped,
 input logic pix_clk,pix_rst_n,pix_enable,pixel_valid,extra_us,
 input logic [15:0] pixel,output wire [15:0] clean_pixel,
 output wire [23:0] latency_bcd,output wire latency_valid,
 output logic [31:0] last_latency_us,output logic [15:0] last_frame_id
);
 localparam integer DIV=CLK_HZ/1000000;
 localparam integer DW=DIV<=1?1:$clog2(DIV);
 logic [DW-1:0] divider='0;logic [47:0] time_us=0;
 // Monotonic across S0: reset must not make retained DDR tags look new.
 always_ff @(posedge sys_clk)begin
  if(divider==DIV-1)begin divider<=0;time_us<=time_us+1'b1;end
  else divider<=divider+1'b1;
 end
 // XPM_CDC_GRAY 2020.2 is limited to 32 bits. Use the supported array
 // synchronizer on an explicitly registered, one-bit-transition 48-bit Gray bus.
 (* KEEP="TRUE" *) logic [47:0] gray_time=0;
 wire [47:0] cam_gray,pix_gray;logic [47:0] cam_time=0,pix_time=0;
 always_ff @(posedge sys_clk)gray_time<=time_us^(time_us>>1);
 xpm_cdc_array_single #(.WIDTH(48),.DEST_SYNC_FF(2),.INIT_SYNC_FF(1),.SRC_INPUT_REG(0),.SIM_ASSERT_CHK(1)) u_cam_time(
  .src_clk(sys_clk),.src_in(gray_time),.dest_clk(cam_clk),.dest_out(cam_gray));
 xpm_cdc_array_single #(.WIDTH(48),.DEST_SYNC_FF(2),.INIT_SYNC_FF(1),.SRC_INPUT_REG(0),.SIM_ASSERT_CHK(1)) u_pix_time(
  .src_clk(sys_clk),.src_in(gray_time),.dest_clk(pix_clk),.dest_out(pix_gray));
 // Fixed-index prefix XORs, registered locally; never split binary epoch words.
 for(genvar g=0;g<48;g++)begin:decode_time
  always_ff @(posedge cam_clk)cam_time[g]<=^cam_gray[47:g];
  always_ff @(posedge pix_clk)pix_time[g]<=^pix_gray[47:g];
 end
 // synthesis translate_off
 logic [47:0] previous_gray=0;
 always @(posedge sys_clk)begin
  if(!$onehot0(gray_time^previous_gray))$fatal(1,"Timestamp Gray transition is not one-hot");
  previous_gray<=gray_time;
 end
 // synthesis translate_on
 acx750_latency_stamp stamp(.clk(cam_clk),.rst_n(cam_rst_n),.sof(cam_sof),.valid(cam_valid),
  .now_us(cam_time),.pixel(cam_pixel),.stamped(cam_stamped));
 wire measured;wire [31:0] measured_us,captured_us;wire [15:0] measured_frame;wire [31:0] bad_tags;
 acx750_latency_probe probe(.clk(pix_clk),.rst_n(pix_rst_n),.enable(pix_enable),.valid(pixel_valid),
  .now_us(pix_time),.pixel(pixel),.extra_us(extra_us),.clean(clean_pixel),
  .sample(measured),.latency_us(measured_us),.captured_us(captured_us),.frame_id(measured_frame),.bad_tags(bad_tags));
 wire full,empty,wr_busy,rd_busy;wire [79:0] result;wire conversion_busy;
 logic fifo_reset;
 always_ff @(posedge pix_clk)fifo_reset<=!pix_rst_n||!pix_enable;
 wire pop=!empty&&!rd_busy&&!conversion_busy&&sys_enable;
 // Metadata only: 16x80 bits in LUTRAM. No video buffering or backpressure.
 xpm_fifo_async #(.FIFO_MEMORY_TYPE("distributed"),.FIFO_WRITE_DEPTH(16),
  .WRITE_DATA_WIDTH(80),.READ_DATA_WIDTH(80),.READ_MODE("fwft"),.FIFO_READ_LATENCY(0),
  .CDC_SYNC_STAGES(2),.USE_ADV_FEATURES("0000"),.SIM_ASSERT_CHK(0)) u_result(
  .rst(fifo_reset),.wr_clk(pix_clk),.rd_clk(sys_clk),.din({captured_us,measured_frame,measured_us}),
  .wr_en(measured&&!full&&!wr_busy),.rd_en(pop),.dout(result),.full(full),.empty(empty),
  .wr_rst_busy(wr_busy),.rd_rst_busy(rd_busy),.sleep(1'b0),.injectsbiterr(1'b0),.injectdbiterr(1'b0));
 acx750_latency_bcd #(.STALE_US(STALE_US)) format(.clk(sys_clk),.rst_n(sys_rst_n),.enable(sys_enable),
  .sample(pop),.now_us(time_us[31:0]),.value_us(result[31:0]),.sample_age_us(time_us[31:0]-result[79:48]),
  .bcd(latency_bcd),.valid(latency_valid),.busy(conversion_busy));
 always_ff @(posedge sys_clk)if(pop)begin last_latency_us<=result[31:0];last_frame_id<=result[47:32];end
endmodule
