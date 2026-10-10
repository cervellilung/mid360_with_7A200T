// ============================================================================
// 本文件从 fpga_ac880/sensor_perception_ar/rtl/lidar_grid.sv 原样搬入，行为未改。
// 原文件名：lidar_grid.sv
// 原路径：fpga_ac880/sensor_perception_ar/rtl/lidar_grid.sv
//
// 【本地改动 2026-10-01】仅为 M3TL type=5 栅格遥测新增一个只读口
//   grid_rd_addr[11:0] / grid_rd_data[7:0]，原有逻辑一行未改：
//   * 只读口只在分析器空闲（as==0，此时 cell_ram 的 B 读口 b_q/b_write 均
//     未被既有逻辑使用）时才把 grid_rd_addr 接到 B 口；其余时刻原 b_addr
//     原样透传，故既有读写时序完全不变。
//   * 读的是“当前累积 bank”的 count（非 0 即视为占用），bank0/bank1 由内部
//     bank 选择。grid_rd_data 位宽恰好等于 cell_t.count（8bit）。
//   * 之所以要加读口：内部 3300 格藏在 cell_ram 双 bank 里，对外原先只暴露
//     objects[0..31]，没有任何读出栅格的口（见 recon_880_perception.md §GAP-E）。
// ============================================================================
`timescale 1ns/1ps
`include "perception_types.svh"
// 2 banks: accumulation and bounded flood fill run independently.
// Bounded sequential point pipeline; two RAM ports. BRAM inference is checked.
module lidar_grid(input logic clk,rst,
 input logic point_valid,output logic point_ready,
 input logic signed [31:0] x,y,z,input logic [63:0] timestamp_ns,now_us,input logic [31:0] scan_index,
 input logic signed [31:0] nx_q30,ny_q30,nz_q30,d_mm,margin_mm,
 input logic [1:0] core_points,
 output logic result_pulse,output wire analysis_busy,output logic [5:0] object_count,
 input logic [4:0] object_index,output object_t object_data,
 output logic [63:0] result_us,
 output logic [31:0] accepted,roi_rejected,ground_rejected,overflow_points,busy_drops,
 // 【本地改动 2026-10-01】只读栅格口
 input  logic [11:0] grid_rd_addr,
 output logic [7:0]  grid_rd_data);
 localparam N=3300;
 cell_t a0,a1,b0,b1;logic [11:0] a_addr,b_addr;
 logic a0_write,a1_write,b0_write,b1_write;
 (* ram_style="block" *) logic [11:0] queue[0:N-1];
 logic [11:0] queue_q,queue_write_addr,queue_write_data;logic queue_write;
 // Single write ports; shallow asynchronous lookup tables use LUTRAM.
 // No array reset: visited is cleared sequentially; objects use object_count.
 (* ram_style="distributed" *) logic visited[0:N-1];
 (* ram_style="distributed" *) object_t objects[0:31];
 logic visit_write,visit_data,object_write;
 logic [11:0] visit_addr;
 logic [4:0] object_write_addr;
 object_t object_write_data;
 cell_t cap_cell,ana_cell,new_cell;
 object_t region;
 logic [12:0] init_index;logic initialized;
 logic bank,ana_bank,ana_busy,pending;
 logic [31:0] bucket;logic have_bucket;
 logic [15:0] input_count;logic [11:0] cap_addr;
 logic signed [31:0] px,py,pz;logic [63:0] pd2;
 logic signed [63:0] plane_x,plane_y,plane_z;
 logic signed [64:0] plane_xy;
 logic signed [95:0] plane_sum;
 logic [3:0] cs;logic [4:0] as;
  logic [12:0] grid_dx,grid_dy;
  logic [25:0] grid_xprod,grid_yprod;
  logic [25:0] distance_x2,distance_y2;
 // 【本地改动 2026-10-01】只读栅格口：仅分析器空闲(as==0)时占用 cell_ram B 读口，
 // 其余时刻原 b_addr 原样透传，既有行为不变。
 logic grid_rd_eff;
 assign grid_rd_eff  = (as==0);                                       // 空闲才接管
 assign grid_rd_data = grid_rd_eff ? (bank ? b1.count : b0.count) : 8'h00;
 logic [11:0] scan,head,tail,current,neighbour,clear_index;
 logic [1:0] direction;logic pass,touches_core;
 logic [5:0] insert_index,move_index;
 logic [63:0] scan_stamp;
 logic eligible,in_bounds;
 logic [24:0] current_row_product;logic [5:0] current_col;
 function automatic logic before_object(input object_t a,b);
  before_object=a.d2<b.d2||(a.d2==b.d2&&(a.x0<b.x0||
    (a.x0==b.x0&&(a.y0<b.y0||(a.y0==b.y0&&a.z0<b.z0)))));
 endfunction
 assign object_data=objects[object_index];
 // Merge mutually exclusive FSM writes before the RAM port. Keeping multiple
 // variable-address assignments in the FSM creates multiport FF/MUX storage.
 always_comb begin
  visit_write=0;visit_addr=clear_index;visit_data=0;
  object_write=0;object_write_addr=insert_index[4:0];object_write_data=region;
  if(!rst&&initialized)begin
   if(as==1)visit_write=1;
   else if(as==14&&!visited[scan]&&eligible)begin
    visit_write=1;visit_addr=scan;visit_data=1;
   end else if(as==16&&eligible&&!visited[neighbour])begin
    visit_write=1;visit_addr=neighbour;visit_data=1;
   end
   if(as==11)begin
    object_write=1;
    if(move_index>insert_index)begin
     object_write_addr=move_index[4:0];object_write_data=objects[move_index-1];
    end
   end
  end
 end
 always_ff @(posedge clk)begin
  if(visit_write)visited[visit_addr]<=visit_data;
  if(object_write)objects[object_write_addr]<=object_write_data;
 end
 // Merge seed and neighbour writes into ONE memory write port. Two indexed
 // nonblocking assignments otherwise expand this queue into ~40k flip-flops.
 always_comb begin
  queue_write=0;queue_write_addr=tail;queue_write_data=neighbour;
  if(initialized&&as==14&&!visited[scan]&&eligible)begin queue_write=1;queue_write_addr=0;queue_write_data=scan;end
  else if(initialized&&as==16&&eligible&&!visited[neighbour])queue_write=1;
 end
 always_ff @(posedge clk)begin
  if(queue_write)queue[queue_write_addr]<=queue_write_data;
  queue_q<=queue[head];
 end
 assign analysis_busy=ana_busy||pending;
 always_comb begin
  a_addr=initialized?cap_addr:(init_index<N?init_index:init_index-N);
  b_addr=scan;
  if(as==5||as==6||as==15)b_addr=current;
  if(as==7||as==8||as==16)b_addr=neighbour;
  if(as==13)b_addr=clear_index;
  a0_write=(!initialized&&init_index<N)||(initialized&&cs==3&&!bank);
  a1_write=(!initialized&&init_index>=N)||(initialized&&cs==3&&bank);
  b0_write=initialized&&as==13&&!ana_bank;
  b1_write=initialized&&as==13&&ana_bank;
 end
 cell_ram #(.WIDTH($bits(cell_t))) bank0(.clk(clk),.a_addr(a_addr),.b_addr(grid_rd_eff?grid_rd_addr:b_addr),.a_write(a0_write),.b_write(b0_write),
  .a_data(initialized?new_cell:233'd0),.b_data(233'd0),.a_q(a0),.b_q(b0));
 cell_ram #(.WIDTH($bits(cell_t))) bank1(.clk(clk),.a_addr(a_addr),.b_addr(grid_rd_eff?grid_rd_addr:b_addr),.a_write(a1_write),.b_write(b1_write),
  .a_data(initialized?new_cell:233'd0),.b_data(233'd0),.a_q(a1),.b_q(b1));
 assign point_ready=initialized&&cs==0&&(!have_bucket||
   scan_index==bucket||!ana_busy&&!pending);
 always_comb begin
  new_cell=cap_cell;
  if(cap_cell.count==0) begin
   new_cell.x0=px;new_cell.y0=py;new_cell.z0=pz;
   new_cell.x1=px;new_cell.y1=py;new_cell.z1=pz;
   new_cell.d2=pd2;new_cell.cx=px;new_cell.cy=py;new_cell.cz=pz;
  end else begin
   if(px<cap_cell.x0)new_cell.x0=px;if(py<cap_cell.y0)new_cell.y0=py;if(pz<cap_cell.z0)new_cell.z0=pz;
   if(px>cap_cell.x1)new_cell.x1=px;if(py>cap_cell.y1)new_cell.y1=py;if(pz>cap_cell.z1)new_cell.z1=pz;
   if(pd2<cap_cell.d2)begin new_cell.d2=pd2;new_cell.cx=px;new_cell.cy=py;new_cell.cz=pz;end
  end
  if(cap_cell.count!=255)new_cell.count=cap_cell.count+1;
  if(cap_cell.points<40000)new_cell.points=cap_cell.points+1;
  in_bounds=1;neighbour=current;
  case(direction)
   0:begin in_bounds=current>=55;neighbour=current-55;end
   1:begin in_bounds=current<3245;neighbour=current+55;end
   2:begin in_bounds=current_col>0;neighbour=current-1;end
   3:begin in_bounds=current_col<54;neighbour=current+1;end
  endcase
  eligible=pass?ana_cell.count==1:ana_cell.count>=core_points;
 end
 always_ff @(posedge clk) begin
  result_pulse<=0;
  if(rst) begin
   init_index<=0;initialized<=0;bank<=0;ana_bank<=1;ana_busy<=0;pending<=0;
   cs<=0;as<=0;have_bucket<=0;input_count<=0;object_count<=0;result_us<=0;
   accepted<=0;roi_rejected<=0;ground_rejected<=0;overflow_points<=0;busy_drops<=0;
  end else if(!initialized) begin
   if(init_index==2*N-1) initialized<=1;else init_index<=init_index+1;
  end else begin
   // A stalled boundary is handled by the upstream full-packet tap. The
   // current bank is never overwritten while the analyzer owns it.
   case(cs)
    0:if(point_valid&&point_ready)begin
     px<=x;py<=y;pz<=z;
     plane_x<=$signed(nx_q30)*$signed(x);
     plane_y<=$signed(ny_q30)*$signed(y);
     plane_z<=$signed(nz_q30)*$signed(z);
     if(!have_bucket)begin have_bucket<=1;bucket<=scan_index;input_count<=1;end
     else if(scan_index!=bucket)begin
      ana_bank<=bank;bank<=!bank;pending<=1;scan_stamp<=now_us;
      bucket<=scan_index;input_count<=1;
     end else if(input_count<40000)input_count<=input_count+1;
     if(have_bucket&&scan_index==bucket&&input_count>=40000)begin overflow_points<=overflow_points+1;end
     else cs<=7;
    end
    7:begin plane_xy<=$signed({plane_x[63],plane_x})+$signed({plane_y[63],plane_y});cs<=8;end
    8:begin plane_sum<=$signed({{31{plane_xy[64]}},plane_xy})+$signed({{32{plane_z[63]}},plane_z});cs<=1;end
    1:begin
     if(px<500||px>=6000||py< -3000||py>=3000) begin roi_rejected<=roi_rejected+1;cs<=0;end
     else if((plane_sum>>>30)+$signed(d_mm)<=$signed(margin_mm))begin ground_rejected<=ground_rejected+1;cs<=0;end
     else begin grid_dx<=px[12:0]-13'd500;grid_dy<=py[12:0]+13'd3000;cs<=5;end
    end
    // ROI has already proved x=500..5999 and y=-3000..2999.
    // Exact 13-bit squares fit 26 bits. Use existing address stages, so this
    // removes the wide DSP cascade without adding latency or changing d2.
    5:begin
     grid_xprod<=grid_dx*13'd5243;grid_yprod<=grid_dy*13'd5243;
     distance_x2<=px[12:0]*px[12:0];
     distance_y2<=$signed(py[12:0])*$signed(py[12:0]);cs<=6;
    end
    6:begin cap_addr<=grid_yprod[24:19]*12'd55+grid_xprod[24:19];pd2<={38'd0,distance_x2}+{38'd0,distance_y2};cs<=2;end
    2:begin cs<=4;end
    4:begin cap_cell<=bank?a1:a0;cs<=3;end
    3:begin accepted<=accepted+1;cs<=0;end
   endcase
   case(as)
    0:if(pending)begin pending<=0;ana_busy<=1;clear_index<=0;object_count<=0;pass<=0;as<=1;end
    1:begin if(clear_index==N-1)begin scan<=0;as<=2;end else clear_index<=clear_index+1;end
    2:begin as<=3;end
    3:begin ana_cell<=ana_bank?b1:b0;as<=14;end
    14:begin
     if(!visited[scan]&&eligible)begin
      head<=0;tail<=1;region<='0;touches_core<=0;as<=4;
     end else as<=12;
    end
    4:if(head<tail)as<=17;else begin insert_index<=0;as<=10;end
    17:begin current<=queue_q;head<=head+1;as<=18;end
    // Exact floor(n/55) for all 0 <= n < 3300. Register each operation;
    // the BRAM output must not feed division plus neighbour control directly.
    18:begin current_row_product<=current*13'd4767;as<=19;end
    19:begin current_col<=current-current_row_product[24:18]*12'd55;as<=5;end
    5:begin as<=6;end
    6:begin ana_cell<=ana_bank?b1:b0;as<=15;end
    15:begin
     region.cells<=region.cells+1;region.points<=region.points+ana_cell.points;
     if(region.cells==0)begin
      region.x0<=ana_cell.x0;region.y0<=ana_cell.y0;region.z0<=ana_cell.z0;
      region.x1<=ana_cell.x1;region.y1<=ana_cell.y1;region.z1<=ana_cell.z1;
      region.d2<=ana_cell.d2;region.cx<=ana_cell.cx;region.cy<=ana_cell.cy;region.cz<=ana_cell.cz;
     end else begin
      if(ana_cell.x0<region.x0)region.x0<=ana_cell.x0;if(ana_cell.y0<region.y0)region.y0<=ana_cell.y0;if(ana_cell.z0<region.z0)region.z0<=ana_cell.z0;
      if(ana_cell.x1>region.x1)region.x1<=ana_cell.x1;if(ana_cell.y1>region.y1)region.y1<=ana_cell.y1;if(ana_cell.z1>region.z1)region.z1<=ana_cell.z1;
      if(ana_cell.d2<region.d2)begin region.d2<=ana_cell.d2;region.cx<=ana_cell.cx;region.cy<=ana_cell.cy;region.cz<=ana_cell.cz;end
     end
     direction<=0;as<=7;
    end
    7:begin if(in_bounds)as<=8;else as<=9;end
    8:begin ana_cell<=ana_bank?b1:b0;as<=16;end
    16:begin
     if(pass&&ana_cell.count>=core_points)touches_core<=1;
     if(eligible&&!visited[neighbour])begin tail<=tail+1;end
     as<=9;
    end
    9:if(direction==3)as<=4;else begin direction<=direction+1;as<=7;end
    10:begin
     if(region.cells<2||region.points<8||(pass&&touches_core))as<=12;
     else if(insert_index==object_count||before_object(region,objects[insert_index]))begin
      if(insert_index<32)begin move_index<=object_count<32?object_count:31;as<=11;end else as<=12;
     end else if(insert_index==31)as<=12;else insert_index<=insert_index+1;
    end
    11:if(move_index>insert_index)begin move_index<=move_index-1;end
       else begin if(object_count<32)object_count<=object_count+1;as<=12;end
    12:if(scan==N-1)begin
      if(!pass&&core_points==2)begin pass<=1;clear_index<=0;as<=1;end
      else begin result_us<=scan_stamp;result_pulse<=1;clear_index<=0;as<=13;end
     end else begin scan<=scan+1;as<=2;end
    13:begin
      if(clear_index==N-1)begin ana_busy<=0;as<=0;end else clear_index<=clear_index+1;
     end
   endcase
  end
 end
endmodule