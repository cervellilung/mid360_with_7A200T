`timescale 1ns/1ps
// Per-camera DVP -> bounded XPM asynchronous FIFO -> system-clock RGB stream.
// Last pixel is withheld until END validates the complete frame. Partial pixels
// must not be published as a display/depth frame until their EOF is accepted.
module stereo_camera_rx #(parameter integer WIDTH=640,HEIGHT=480,FIFO_DEPTH=2048,SKIP_FRAMES=10)(
 input logic sys_clk,arst,configured,input logic [63:0] now_us,
 input logic pclk,vsync,href,input logic [7:0] data,
 output logic out_valid,input logic out_ready,output logic [15:0] rgb,
 output logic sof,eof,output logic [31:0] frame_id,output logic [63:0] stamp_us,
 output logic [31:0] complete_frames,bad_frames,output logic overflow_seen);
 localparam CW=$clog2(FIFO_DEPTH)+1,PCW=$clog2(WIDTH*HEIGHT+2);
 wire prst,srst,enabled;
 xpm_cdc_async_rst #(.DEST_SYNC_FF(5),.INIT_SYNC_FF(0),.RST_ACTIVE_HIGH(1))
  p_reset(.src_arst(arst),.dest_clk(pclk),.dest_arst(prst));
 xpm_cdc_async_rst #(.DEST_SYNC_FF(2),.INIT_SYNC_FF(0),.RST_ACTIVE_HIGH(1))
  s_reset(.src_arst(arst),.dest_clk(sys_clk),.dest_arst(srst));
 xpm_cdc_single #(.DEST_SYNC_FF(2),.INIT_SYNC_FF(1),.SRC_INPUT_REG(1))
  init_sync(.src_clk(sys_clk),.src_in(configured),.dest_clk(pclk),.dest_out(enabled));
 wire tv,full,empty,wb,rb,source_overflow;wire [17:0] td,q;
 wire token_ready=enabled&&!arst&&!prst&&!full&&!wb;
 stereo_dvp_tokens #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.SKIP_FRAMES(SKIP_FRAMES))
  capture(pclk,prst,enabled,vsync,href,data,tv,token_ready,td,source_overflow);
 xpm_cdc_single #(.DEST_SYNC_FF(2),.INIT_SYNC_FF(1),.SRC_INPUT_REG(0))
  overflow_sync(.src_clk(pclk),.src_in(source_overflow),.dest_clk(sys_clk),.dest_out(overflow_seen));
 wire pop=configured&&!arst&&!srst&&!rb&&!empty&&(!out_valid||out_ready);
 xpm_fifo_async #(.FIFO_MEMORY_TYPE("block"),.FIFO_WRITE_DEPTH(FIFO_DEPTH),
  .WRITE_DATA_WIDTH(18),.READ_DATA_WIDTH(18),.READ_MODE("fwft"),.FIFO_READ_LATENCY(0),
  .CDC_SYNC_STAGES(2),.DOUT_RESET_VALUE("0"),.WR_DATA_COUNT_WIDTH(CW),.RD_DATA_COUNT_WIDTH(CW),
  // Vivado 2020.2's S-5 checker requires an asynchronous pointer to cross in
  // one clock, contrary to CDC_SYNC_STAGES=2. Check legal port use in our TB.
  .USE_ADV_FEATURES("0000"),.SIM_ASSERT_CHK(0)) fifo(
  .rst(prst),.wr_clk(pclk),.rd_clk(sys_clk),.din(td),.wr_en(tv&&token_ready),
  .rd_en(pop),.dout(q),.full(full),.empty(empty),.wr_rst_busy(wb),.rd_rst_busy(rb),
  .sleep(1'b0),.injectsbiterr(1'b0),.injectdbiterr(1'b0),.almost_empty(),.almost_full(),
  .data_valid(),.dbiterr(),.overflow(),.prog_empty(),.prog_full(),.rd_data_count(),
  .sbiterr(),.underflow(),.wr_ack(),.wr_data_count());
 logic pending,in_frame,pending_sof;
 logic [15:0] last_pixel;logic [PCW-1:0] pixels;
 logic [31:0] id;logic [63:0] stamp;
 always_ff @(posedge sys_clk)begin
  if(srst)begin
   out_valid<=0;pending<=0;in_frame<=0;pixels<=0;id<=0;complete_frames<=0;bad_frames<=0;
  end else if(!out_valid||out_ready)begin
   out_valid<=0;
   if(pop)case(q[17:16])
    2'b01:begin
     if(in_frame)bad_frames<=bad_frames+1'b1;
     pending<=0;pixels<=0;in_frame<=1;id<=id+1'b1;stamp<=now_us;
    end
    2'b00:if(in_frame)begin
     if(pending)begin rgb<=last_pixel;sof<=pending_sof;eof<=0;frame_id<=id;stamp_us<=stamp;out_valid<=1;end
     pending<=1;pending_sof<=pixels==0;last_pixel<=q[15:0];
     if(pixels<WIDTH*HEIGHT+1)pixels<=pixels+1'b1;
    end
    2'b10:begin
     if(in_frame&&pending&&q[0]&&pixels==WIDTH*HEIGHT)begin
      rgb<=last_pixel;sof<=pending_sof;eof<=1;frame_id<=id;stamp_us<=stamp;out_valid<=1;
      complete_frames<=complete_frames+1'b1;
     end else bad_frames<=bad_frames+1'b1;
     pending<=0;in_frame<=0;
    end
    default:begin pending<=0;in_frame<=0;bad_frames<=bad_frames+1'b1;end
   endcase
  end
 end
endmodule
