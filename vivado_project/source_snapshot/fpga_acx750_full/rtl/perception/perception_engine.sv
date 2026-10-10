// ============================================================================
// 本文件从 fpga_ac880/sensor_perception_ar/rtl/perception_engine.sv 原样搬入，行为未改。
// 原文件名：perception_engine.sv
// 原路径：fpga_ac880/sensor_perception_ar/rtl/perception_engine.sv
//
// 【本地改动 2026-10-01】仅为适配 750 的最小改动，行为未改：
//   1) 新增栅格只读透传口 grid_rd_addr[11:0]/grid_rd_data[7:0]，原样透传给
//      内部 lidar_grid（从顶层 acx750_grid_reader 读 M3TL type=5 栅格用；
//      位宽 [11:0] 与 rtl/video/acx750_ar_wrap.sv 已接好的口径一致）。
//   2) 新增参数 VIDEO_HZ（默认 33_333_333，= 750 像素钟），并下传给 ar_video。
//      880 上该参数默认 200_000_000；750 像素钟是 33.333 MHz，若不下传会把
//      “陈旧目标清除窗口”放大 ~6 倍（框线迟迟不消失）。ar_video 内用
//      VIDEO_HZ/1000000 做整数除法换算像素拍数，33_333_333/1_000_000=33（不
//      做额外处理，但要求像素钟与 VIDEO_HZ 同步维护）。
// ============================================================================
`timescale 1ns/1ps
`include "perception_types.svh"
module perception_engine #(
  parameter integer VIDEO_HZ = 33_333_333   // 【本地改动 2026-10-01】750 像素钟
)(input logic clk,rst,input logic [63:0] now_us,
 input logic [7:0] radar_data,input logic radar_valid,radar_last,
 input logic [7:0] odom_data,input logic odom_valid,odom_last,
 input logic [31:0] source_fifo_overflow,source_eth_rejected,source_odom_bad,source_odom_busy,source_radar_slot_drops,source_chassis_slot_drops,
 input logic [2047:0] cfg,input logic [7071:0] lut,
 input logic cfg_pending,output logic cfg_safe,
 output logic snapshot_start,output logic [1023:0] metadata,
 input logic [4:0] snapshot_index,input logic snapshot_busy,output logic [383:0] snapshot_object,
 input logic [11:0] grid_rd_addr,output logic [7:0] grid_rd_data,   // 【本地改动 2026-10-01】栅格只读透传口
 input logic video_clk,video_rst,
 input logic [15:0] video_data,input logic video_valid,video_sof,video_eol,
 output logic video_ready,output logic [15:0] out_data,
 output logic out_valid,out_sof,out_eol,input logic out_ready);
 logic [7:0] tap_data;logic tap_valid,tap_last,tap_ready;logic [31:0] tap_drops;
 logic pv,pr,grid_ready,analysis_busy,boundary,ownership_block;logic signed [31:0] px,py,pz;
 logic [31:0] scan_index;logic [63:0] ts;logic [31:0] bad,good,nocrc;
 logic [31:0] previous_bucket;logic first_point;
 logic [5:0] count;logic [4:0] project_index;logic grid_pulse;
 object_t obj;logic [63:0] result_us;
 logic [31:0] accepted,roi,ground,overflow,grid_busy_drops;
 logic [5:0] odom_index;logic signed [15:0] vx,vy;logic odom_frame;
 logic motion_valid,motion_updated;logic [31:0] speed,filtered,rejected,motion_overflow;
 logic [63:0] distance_um,motion_us;
 logic projector_busy,project_done,project_start,wait_snapshot;
 logic [31:0] boxes;logic [351:0] bx0,bx1;logic [319:0] by0,by1;logic [191:0] disp;
 logic [31:0] nearest;logic [1:0] risk;logic [7:0] lut_index;logic [31:0] lut_sample;
 logic publish,publish_ready;logic [31:0] publish_drops;
 logic [63:0] age_value;
 wire test_mode=cfg[11*32+1];
 logic [63:0] last_test_us,last_snapshot_us;
 assign snapshot_object=obj;
 assign boundary=first_point||scan_index!=previous_bucket;
 assign ownership_block=boundary&&(projector_busy||project_start||snapshot_busy||wait_snapshot||snapshot_start);
 assign pr=grid_ready&&!cfg_pending&&!ownership_block;
 assign cfg_safe=!ownership_block&&!analysis_busy&&(first_point||(pv&&grid_ready&&boundary));
 assign lut_sample=lut[lut_index*32+:32];
 assign age_value=now_us-result_us;
 packet_tap tap(.clk(clk),.rst(rst),.s_data(radar_data),.s_valid(radar_valid),.s_last(radar_last),
  .m_data(tap_data),.m_valid(tap_valid),.m_last(tap_last),.m_ready(tap_ready),.drops(tap_drops));
 mid360_points parser(.clk(clk),.rst(rst),.s_data(tap_data),.s_valid(tap_valid),.s_last(tap_last),.s_ready(tap_ready),
  .point_valid(pv),.point_ready(pr),.x(px),.y(py),.z(pz),.timestamp_ns(ts),.scan_index(scan_index),.bad_packets(bad),.good_packets(good),.crc_unavailable(nocrc));
 lidar_grid grid(.clk(clk),.rst(rst),.point_valid(pv&&!cfg_pending&&!ownership_block),.point_ready(grid_ready),.x(px),.y(py),.z(pz),.timestamp_ns(ts),.scan_index(scan_index),.now_us(now_us),
  .nx_q30(cfg[0+:32]),.ny_q30(cfg[32+:32]),.nz_q30(cfg[64+:32]),.d_mm(cfg[96+:32]),.margin_mm(cfg[128+:32]),.core_points(cfg[160+:2]),
  .result_pulse(grid_pulse),.analysis_busy(analysis_busy),.object_count(count),.object_index(snapshot_busy?snapshot_index:project_index),.object_data(obj),.result_us(result_us),
  .accepted(accepted),.roi_rejected(roi),.ground_rejected(ground),.overflow_points(overflow),.busy_drops(grid_busy_drops),
  .grid_rd_addr(grid_rd_addr),.grid_rd_data(grid_rd_data));   // 【本地改动 2026-10-01】栅格只读透传
 chassis_motion motion(.clk(clk),.rst(rst),.frame_valid(odom_frame),.vx_raw(vx),.vy_raw(vy),.now_us(now_us),
  .valid(motion_valid),.updated(motion_updated),.speed_mm_s(speed),.filtered_mm_s(filtered),.distance_um(distance_um),.last_us(motion_us),
  .rejected(rejected),.overflow_frames(motion_overflow));
 fixed_projector project(.clk(clk),.rst(rst),.start(project_start),.count(count),.object_index(project_index),.object_data(obj),
  .calibrated(cfg[192]),.rotation(cfg[16*32+:9*32]),.translation(cfg[25*32+:3*32]),
  .fx(cfg[7*32+:32]),.fy(cfg[8*32+:32]),.cx(cfg[9*32+:32]),.cy(cfg[10*32+:32]),
  .stereo_gain(cfg[14*32+:32]),.warning_mm(cfg[12*32+:32]),.danger_mm(cfg[13*32+:32]),
  .lut_index(lut_index),.lut_du(lut_sample[15:0]),.lut_dv(lut_sample[31:16]),
  .busy(projector_busy),.done(project_done),.box_valid(boxes),.x0(bx0),.x1(bx1),.y0(by0),.y1(by1),.disparity(disp),.nearest_mm(nearest),.risk(risk));
 ar_video #(.VIDEO_HZ(VIDEO_HZ)) overlay(.control_clk(clk),.control_rst(rst),.publish(publish),.publish_ready(publish_ready),
  .boxes(test_mode?32'd1:boxes),.bx0(test_mode?352'd300:bx0),.bx1(test_mode?352'd500:bx1),
  .by0(test_mode?320'd150:by0),.by1(test_mode?320'd350:by1),.shifts(test_mode?192'd12:disp),.stereo(cfg[11*32]),.test_mode(test_mode),
  .radar_age_us(test_mode?32'd0:(age_value>32'hffffffff ?32'hffffffff:age_value[31:0])),.nearest_mm(test_mode?32'd1300:nearest),.speed_mm_s(filtered),
  .travel_mm(distance_um/1000),.motion_valid(motion_valid),.risk(test_mode?2'd1:risk),
  .motion_age_us(now_us-motion_us>32'hffffffff ?32'hffffffff:now_us-motion_us),
  .clk(video_clk),.rst(video_rst),.s_data(video_data),.s_valid(video_valid),.s_sof(video_sof),.s_eol(video_eol),.s_ready(video_ready),
  .m_data(out_data),.m_valid(out_valid),.m_sof(out_sof),.m_eol(out_eol),.m_ready(out_ready));
 always_comb begin
  metadata=0;
  metadata[0+:32]=32'h31524550;metadata[32+:32]=1;
  metadata[64+:32]={22'b0,test_mode,cfg[192],motion_valid,(result_us!=0),count};
  metadata[96+:32]=result_us[31:0];metadata[128+:32]=result_us[63:32];
  metadata[160+:32]=speed;metadata[192+:32]=filtered;
  metadata[224+:32]=distance_um[31:0];metadata[256+:32]=distance_um[63:32];
  metadata[288+:32]=motion_us[31:0];metadata[320+:32]=motion_us[63:32];
  metadata[352+:32]=accepted;metadata[384+:32]=roi;metadata[416+:32]=ground;
  metadata[448+:32]=overflow;metadata[480+:32]=tap_drops;
  metadata[512+:32]=bad;metadata[544+:32]=good;metadata[576+:32]=nocrc;
  metadata[608+:32]=rejected;metadata[640+:32]=motion_overflow;metadata[672+:32]=publish_drops;
  metadata[704+:32]=now_us[31:0];metadata[736+:32]=now_us[63:32];
  metadata[768+:32]=source_fifo_overflow;metadata[800+:32]=source_eth_rejected;
  metadata[832+:32]=source_odom_bad;metadata[864+:32]=source_odom_busy;
  metadata[896+:32]=source_radar_slot_drops;metadata[928+:32]=source_chassis_slot_drops;
 end
 always_ff @(posedge clk)begin
  odom_frame<=0;project_start<=0;publish<=0;snapshot_start<=0;
  if(rst)begin odom_index<=0;vx<=0;vy<=0;first_point<=1;previous_bucket<=0;wait_snapshot<=0;publish_drops<=0;last_test_us<=0;last_snapshot_us<=0;end
  else begin
   if(pv&&pr)begin previous_bucket<=scan_index;first_point<=0;end
   if(odom_valid)begin
    case(odom_index)25:vx[7:0]<=odom_data;26:vx[15:8]<=odom_data;27:vy[7:0]<=odom_data;28:vy[15:8]<=odom_data;endcase
    if(odom_last)begin odom_index<=0;if(odom_index==59)odom_frame<=1;end else odom_index<=odom_index+1;
   end
   if(grid_pulse)begin snapshot_start<=1;wait_snapshot<=1;end
   // Copying the table owns its read port before projection starts.
   if(wait_snapshot&&!snapshot_busy&&!snapshot_start)begin project_start<=1;wait_snapshot<=0;end
   if(project_done)begin if(publish_ready)publish<=1;else publish_drops<=publish_drops+1;end
   if(motion_updated&&!analysis_busy&&!projector_busy&&!wait_snapshot&&!snapshot_busy&&!grid_pulse)begin
    snapshot_start<=1;
    if(publish_ready)publish<=1;
   end
   if(test_mode&&now_us-last_test_us>=100000&&!analysis_busy&&!projector_busy&&!wait_snapshot&&!snapshot_busy&&!snapshot_start)begin
    last_test_us<=now_us;snapshot_start<=1;if(publish_ready)publish<=1;
   end
   // Diagnostic heartbeat still exposes bad-source counters when no valid
   // radar/Odom arrives. Detection timestamp remains unchanged, so consumers
   // retire old targets instead of treating a heartbeat as a new scan.
   if(snapshot_start)last_snapshot_us<=now_us;
   if(now_us-last_snapshot_us>=10000&&!analysis_busy&&!projector_busy&&!project_start&&!wait_snapshot&&!snapshot_busy&&!snapshot_start&&!grid_pulse)
    snapshot_start<=1;
  end
 end
endmodule