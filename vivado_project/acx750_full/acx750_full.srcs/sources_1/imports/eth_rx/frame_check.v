/////////////////////////////////////////////////////////////////////////////////
// Company       : 武汉芯路恒科技有限公司
//                 http://xiaomeige.taobao.com
// Web           : http://www.corecourse.cn
// 
// Create Date   : 2022/10/23 00:00:00
// Module Name   : frame_check
// Description   : 判断每包数据的序号是否连续，如果不连续将整帧图像数据丢弃
// 
// Dependencies  : 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
/////////////////////////////////////////////////////////////////////////////////

module frame_check
#(
  parameter IMAGE_WIDTH  = 800,
  parameter IMAGE_HEIGHT = 480,
  parameter DATA_WIDTH   = 16
)
(
  input                      clk,
  input                      reset,

  input     [DATA_WIDTH-1:0] data_i,
  input                      data_i_valid,

  output reg                 data_o_valid,
  output reg[DATA_WIDTH-1:0] data_o,
  output reg                 frame_dis_pulse
);

  reg                  data_i_valid_dly1;
  reg                  data_i_valid_dly2;
  wire                 data_i_valid_rising;
  reg [DATA_WIDTH-1:0] data_i_dly1;
  
  reg [DATA_WIDTH-1:0] data_row_num;
  reg [DATA_WIDTH-1:0] check_row_num;
  reg                  check_flag;
  reg                  frame_dis_flag;
  reg                  frame_dis_flag_dly1;
  reg                  frame_dis_flag_dly2;

  always@(posedge clk)
  begin
    data_i_valid_dly1 <= data_i_valid;
    data_i_valid_dly2 <= data_i_valid_dly1;

    data_i_dly1 <= data_i;
  end

  assign data_i_valid_rising = data_i_valid_dly1 && (~data_i_valid_dly2);

  always@(posedge clk or posedge reset)
  begin
    if(reset)
      data_row_num <= 'd0;
    else if(data_i_valid_rising)
      data_row_num <= data_i_dly1;
    else
      data_row_num <= 'd0;
  end

  always@(posedge clk or posedge reset)
  begin
    if(reset)
      check_flag <= 1'b0;
    else if(data_i_valid_rising)
      check_flag <= 1'b1;
    else
      check_flag <= 1'b0;
  end

  always@(posedge clk or posedge reset)
  begin
    if(reset)
      check_row_num <= 'd0;
    else if(check_flag == 1'b1)
    begin
      if(check_row_num == IMAGE_HEIGHT - 1'b1)
        check_row_num <= 'd0;
      else
        check_row_num <= check_row_num + 1'd1;
    end
    else if(data_i_valid_rising && (data_i_dly1 == 'd0))
      check_row_num <= 'd0;
    else
      check_row_num <= check_row_num;
  end

  //output ctrl
  always@(posedge clk or posedge reset)
  begin
    if(reset)
      frame_dis_flag <= 1'b0;
    else if(data_i_valid_rising && (data_i_dly1 == 'd0))
      frame_dis_flag <= 1'b0;
    else if(check_flag && (check_row_num != data_row_num))
      frame_dis_flag <= 1'b1;
    else
      frame_dis_flag <= frame_dis_flag;
  end

  always@(posedge clk)
  begin
    frame_dis_flag_dly1 <= frame_dis_flag;
    frame_dis_flag_dly2 <= frame_dis_flag_dly1;
  end

  always@(posedge clk or posedge reset)
  begin
    if(reset)
      frame_dis_pulse <= 1'b0;
    else if(frame_dis_flag && (~frame_dis_flag_dly2))
      frame_dis_pulse <= 1'b1;
    else
      frame_dis_pulse <= 1'b0;
  end

  //output data
  always@(posedge clk or posedge reset)
  begin
    if(reset)
    begin
      data_o       <= 'd0;
      data_o_valid <= 'd0;
    end
    else if(data_i_valid_dly1 && data_i_valid_dly2 && (~frame_dis_flag))
    begin
      data_o       <= data_i_dly1;
      data_o_valid <= 1'd1;
    end
    else
    begin
      data_o       <= 'd0;
      data_o_valid <= 'd0;
    end
  end

endmodule