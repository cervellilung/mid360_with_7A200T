// ============================================================================
// 本文件从 fpga_ac880/sensor_perception_ar/rtl/perception_regs.sv 原样搬入，行为未改。
// 原文件名：perception_regs.sv
// 原路径：fpga_ac880/sensor_perception_ar/rtl/perception_regs.sv
//
// TODO(750): 本模块是 4 KiB AXI-Lite 从设备（s_axi_* 端口），在 AC880 上由 PS(ARM)
//   作为 AXI 主机驱动。ACX750 是纯 FPGA、无 PS，本模块本身是纯 RTL（无 Xilinx IP/
//   xpm 依赖）可正常展开，但**需要一个 AXI-Lite 主机**才能配置与回读；该主机在 750
//   上尚不存在（原 perception_regs_axi.v 也未搬入）。这正是移植缺口 G11：需为 750 补
//   一个 PL 侧控制面（例如把 UART/以太网下行命令翻译成 AXI-Lite 主时序，或直接改接
//   寄存器接口）。在补齐之前，本模块只能以常量/测试激励固定配置运行。
// ============================================================================
// Full banked LUT: original snapshot behavior retained.
`timescale 1ns/1ps
// 4 KiB AXI-Lite page, independent AW/W acceptance, one response at a time.
module perception_regs(input logic s_axi_aclk,s_axi_aresetn,
 input logic [11:0] s_axi_awaddr,input logic [2:0] s_axi_awprot,input logic s_axi_awvalid,output logic s_axi_awready,
 input logic [31:0] s_axi_wdata,input logic [3:0] s_axi_wstrb,input logic s_axi_wvalid,output logic s_axi_wready,
 output logic [1:0] s_axi_bresp,output logic s_axi_bvalid,input logic s_axi_bready,
 input logic [11:0] s_axi_araddr,input logic [2:0] s_axi_arprot,input logic s_axi_arvalid,output logic s_axi_arready,
 output logic [31:0] s_axi_rdata,output logic [1:0] s_axi_rresp,output logic s_axi_rvalid,input logic s_axi_rready,
 output logic [2047:0] config_words,
 input logic [7:0] lut_index,output wire [31:0] lut_word,
 output logic config_pending,input logic config_safe,
 input logic snapshot_start,input logic [1023:0] metadata,input logic [383:0] object_data,
 output logic [4:0] object_index,output logic snapshot_busy);
 logic [31:0] shadow[0:63],cfg[0:63];
 localparam [1:0] INIT=0,READY=1,CLONE_READ=2,CLONE_WRITE=3;
 logic [1:0] table_state;
 logic active_bank;
 logic [7:0] copy_lut;
 (* ram_style="block" *) logic [31:0] table0[0:220],table1[0:220];
 logic [31:0] query0,query1,read0,read1;
 logic table_read_pending,read_bank;
 logic [31:0] snapshot_metadata[0:31];logic [31:0] seq;
 // Objects retain their old value until each record is overwritten. Only the
 // validity bitmap resets, so uninitialised block RAM is never exposed on AXI.
 logic [31:0] record_valid;
 logic [31:0] object_bank_q[0:11];
 logic object_read_pending,read_record_valid;
 logic [3:0] read_field;
 wire [11:0] object_offset=s_axi_araddr-12'h880;
 wire [8:0] object_word=object_offset[10:2];
 wire [4:0] read_record=object_word/9'd12;
 wire [3:0] object_field=object_word%9'd12;
 wire object_read_accept=s_axi_arvalid&&s_axi_arready&&
                         s_axi_araddr>=12'h880&&s_axi_araddr<12'he80;
 logic aw_hold,w_hold;logic [11:0] aw;logic [31:0] wd;logic [3:0] ws;
 logic [5:0] copy_index;integer j,k,idx;
 assign s_axi_awready=table_state==READY&&!config_pending&&!aw_hold&&!s_axi_bvalid;
 assign s_axi_wready=table_state==READY&&!config_pending&&!w_hold&&!s_axi_bvalid;
 assign s_axi_arready=table_state==READY&&!s_axi_rvalid&&!object_read_pending&&!table_read_pending;
 assign object_index=copy_index[4:0];
 generate for(genvar g=0;g<64;g=g+1)assign config_words[g*32+:32]=cfg[g];endgenerate
 // Two true-dual-port BRAM banks: projector A, AXI/clone B.
 wire table_write=aw_hold&&w_hold&&!s_axi_bvalid&&table_state==READY&&aw>=12'h400&&aw<12'h774;
 wire table_read=s_axi_arvalid&&s_axi_arready&&s_axi_araddr>=12'h400&&s_axi_araddr<12'h774;
 wire cloning=table_state==CLONE_READ||table_state==CLONE_WRITE;
 wire [7:0] b_addr=(table_state==INIT||cloning)?copy_lut:table_write?aw[9:2]:table_read?s_axi_araddr[9:2]:8'd0;
 wire [31:0] table_data=table_state==INIT?32'd0:cloning?(active_bank?read1:read0):wd;
 wire [3:0] table_mask=table_state==INIT||table_state==CLONE_WRITE?4'hf:ws;
 wire write0=table_state==INIT||(table_state==CLONE_WRITE&&active_bank)||(table_write&&active_bank);
 wire write1=table_state==INIT||(table_state==CLONE_WRITE&&!active_bank)||(table_write&&!active_bank);
 assign lut_word=table_state==INIT?32'd0:active_bank?query1:query0;
 always_ff @(posedge s_axi_aclk)begin
  if(lut_index<221)begin query0<=table0[lut_index];query1<=table1[lut_index];end
  else begin query0<=0;query1<=0;end
  for(integer lane=0;lane<4;lane=lane+1)begin
   if(write0&&table_mask[lane])table0[b_addr][lane*8+:8]<=table_data[lane*8+:8];
   if(write1&&table_mask[lane])table1[b_addr][lane*8+:8]<=table_data[lane*8+:8];
  end
  read0<=table0[b_addr];read1<=table1[b_addr];
 end
 // Each field is an independent synchronous single-write/single-read bank.
 // Both operations use one clock and nonblocking assignments: a collision
 // returns the old word (READ_FIRST), matching the former register array.
 generate for(genvar field=0;field<12;field=field+1)begin:g_snapshot_bank
  (* ram_style="block" *) logic [31:0] memory[0:31];
  always_ff @(posedge s_axi_aclk)begin
   if(snapshot_busy)
    memory[copy_index[4:0]]<=object_data[(11-field)*32+:32];
   if(object_read_accept)object_bank_q[field]<=memory[read_record];
  end
 end endgenerate
 always_ff @(posedge s_axi_aclk)begin
  if(!s_axi_aresetn)begin
   aw_hold<=0;w_hold<=0;s_axi_bvalid<=0;s_axi_rvalid<=0;s_axi_bresp<=0;s_axi_rresp<=0;
   config_pending<=0;snapshot_busy<=0;seq<=0;copy_index<=0;
   table_state<=INIT;active_bank<=0;copy_lut<=0;table_read_pending<=0;read_bank<=0;
   record_valid<=0;object_read_pending<=0;read_record_valid<=0;read_field<=0;
   for(j=0;j<64;j=j+1)begin shadow[j]<=0;cfg[j]<=0;end
   shadow[2]<=32'h40000000;cfg[2]<=32'h40000000;
   shadow[4]<=100;cfg[4]<=100;shadow[5]<=2;cfg[5]<=2;
   shadow[12]<=2000;cfg[12]<=2000;shadow[13]<=1000;cfg[13]<=1000;shadow[14]<=17500;cfg[14]<=17500;
   for(j=0;j<32;j=j+1)snapshot_metadata[j]<=0;
  end else begin
   if(s_axi_awvalid&&s_axi_awready)begin aw<=s_axi_awaddr;aw_hold<=1;end
   if(s_axi_wvalid&&s_axi_wready)begin wd<=s_axi_wdata;ws<=s_axi_wstrb;w_hold<=1;end
   if(s_axi_bvalid&&s_axi_bready)s_axi_bvalid<=0;
   if(aw_hold&&w_hold&&!s_axi_bvalid&&table_state==READY)begin
    aw_hold<=0;w_hold<=0;s_axi_bvalid<=1;s_axi_bresp<=0;
    if(aw==12'h008)begin if(ws[0]&&wd[0])config_pending<=1;end
    else if(aw>=12'h100&&aw<12'h200)begin
     idx=(aw-12'h100)>>2;for(k=0;k<4;k=k+1)if(ws[k])shadow[idx][k*8+:8]<=wd[k*8+:8];
    end else if(aw>=12'h400&&aw<12'h774)begin
     // Byte write is performed by the synchronous BRAM process above.
    end else s_axi_bresp<=2;
   end
   case(table_state)
    INIT:if(copy_lut==220)begin copy_lut<=0;table_state<=READY;end else copy_lut<=copy_lut+1'b1;
    CLONE_READ:table_state<=CLONE_WRITE;
    CLONE_WRITE:if(copy_lut==220)begin config_pending<=0;table_state<=READY;end
     else begin copy_lut<=copy_lut+1'b1;table_state<=CLONE_READ;end
    default:;
   endcase
   if(config_pending&&config_safe&&table_state==READY)begin
    for(j=0;j<64;j=j+1)cfg[j]<=shadow[j];
    active_bank<=!active_bank;copy_lut<=0;table_state<=CLONE_READ;
   end
   if(s_axi_rvalid&&s_axi_rready)s_axi_rvalid<=0;
   if(s_axi_arvalid&&s_axi_arready)begin
    s_axi_rvalid<=!object_read_accept&&!table_read;s_axi_rresp<=0;s_axi_rdata<=0;
    if(s_axi_araddr==0)s_axi_rdata<=32'h31524550;
    else if(s_axi_araddr==4)s_axi_rdata<=seq;
    else if(s_axi_araddr==8)s_axi_rdata<={30'b0,snapshot_busy,config_pending};
    else if(s_axi_araddr>=12'h100&&s_axi_araddr<12'h200)s_axi_rdata<=cfg[(s_axi_araddr-12'h100)>>2];
    else if(table_read)begin table_read_pending<=1;read_bank<=active_bank;end
    else if(s_axi_araddr>=12'h800&&s_axi_araddr<12'h880)
     s_axi_rdata<=snapshot_metadata[(s_axi_araddr-12'h800)>>2];
    else if(object_read_accept)begin
     object_read_pending<=1;
     read_field<=object_field;
     // Capture validity at AR acceptance, before a colliding first write.
     read_record_valid<=record_valid[read_record];
    end
    else s_axi_rresp<=2;
   end
   if(table_read_pending)begin
    s_axi_rdata<=read_bank?read1:read0;s_axi_rresp<=0;s_axi_rvalid<=1;table_read_pending<=0;
   end
   if(object_read_pending)begin
    s_axi_rdata<=read_record_valid?object_bank_q[read_field]:32'd0;
    s_axi_rresp<=0;s_axi_rvalid<=1;object_read_pending<=0;
   end
   if(snapshot_start&&!snapshot_busy)begin
    seq<=seq+1;snapshot_busy<=1;copy_index<=0;
    for(j=0;j<32;j=j+1)snapshot_metadata[j]<=metadata[j*32+:32];
   end else if(snapshot_busy)begin
    record_valid[copy_index[4:0]]<=1;
    if(copy_index==31)begin snapshot_busy<=0;seq<=seq+1;end else copy_index<=copy_index+1;
   end
  end
 end
endmodule
