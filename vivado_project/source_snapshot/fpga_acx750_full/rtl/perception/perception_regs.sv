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
`timescale 1ns/1ps
// 4 KiB AXI-Lite page, independent AW/W acceptance, one response at a time.
module perception_regs(input logic s_axi_aclk,s_axi_aresetn,
 input logic [11:0] s_axi_awaddr,input logic [2:0] s_axi_awprot,input logic s_axi_awvalid,output logic s_axi_awready,
 input logic [31:0] s_axi_wdata,input logic [3:0] s_axi_wstrb,input logic s_axi_wvalid,output logic s_axi_wready,
 output logic [1:0] s_axi_bresp,output logic s_axi_bvalid,input logic s_axi_bready,
 input logic [11:0] s_axi_araddr,input logic [2:0] s_axi_arprot,input logic s_axi_arvalid,output logic s_axi_arready,
 output logic [31:0] s_axi_rdata,output logic [1:0] s_axi_rresp,output logic s_axi_rvalid,input logic s_axi_rready,
 output logic [2047:0] config_words,output logic [7071:0] lut_words,
 output logic config_pending,input logic config_safe,
 input logic snapshot_start,input logic [1023:0] metadata,input logic [383:0] object_data,
 output logic [4:0] object_index,output logic snapshot_busy);
 logic [31:0] shadow[0:63],cfg[0:63];logic [31:0] lut_shadow[0:220],lut[0:220];
 logic [31:0] snapshot[0:415];logic [31:0] seq;
 logic aw_hold,w_hold;logic [11:0] aw;logic [31:0] wd;logic [3:0] ws;
 logic [5:0] copy_index;integer j,k,idx;
 assign s_axi_awready=!aw_hold&&!s_axi_bvalid;
 assign s_axi_wready=!w_hold&&!s_axi_bvalid;
 assign s_axi_arready=!s_axi_rvalid;
 assign object_index=copy_index[4:0];
 generate for(genvar g=0;g<64;g=g+1)assign config_words[g*32+:32]=cfg[g];endgenerate
 generate for(genvar g=0;g<221;g=g+1)assign lut_words[g*32+:32]=lut[g];endgenerate
 always_ff @(posedge s_axi_aclk)begin
  if(!s_axi_aresetn)begin
   aw_hold<=0;w_hold<=0;s_axi_bvalid<=0;s_axi_rvalid<=0;s_axi_bresp<=0;s_axi_rresp<=0;
   config_pending<=0;snapshot_busy<=0;seq<=0;copy_index<=0;
   for(j=0;j<64;j=j+1)begin shadow[j]<=0;cfg[j]<=0;end
   shadow[2]<=32'h40000000;cfg[2]<=32'h40000000;
   shadow[4]<=100;cfg[4]<=100;shadow[5]<=2;cfg[5]<=2;
   shadow[12]<=2000;cfg[12]<=2000;shadow[13]<=1000;cfg[13]<=1000;shadow[14]<=17500;cfg[14]<=17500;
   for(j=0;j<221;j=j+1)begin lut[j]<=0;lut_shadow[j]<=0;end
   for(j=0;j<416;j=j+1)snapshot[j]<=0;
  end else begin
   if(s_axi_awvalid&&s_axi_awready)begin aw<=s_axi_awaddr;aw_hold<=1;end
   if(s_axi_wvalid&&s_axi_wready)begin wd<=s_axi_wdata;ws<=s_axi_wstrb;w_hold<=1;end
   if(s_axi_bvalid&&s_axi_bready)s_axi_bvalid<=0;
   if(aw_hold&&w_hold&&!s_axi_bvalid)begin
    aw_hold<=0;w_hold<=0;s_axi_bvalid<=1;s_axi_bresp<=0;
    if(aw==12'h008)begin if(ws[0]&&wd[0])config_pending<=1;end
    else if(aw>=12'h100&&aw<12'h200)begin
     idx=(aw-12'h100)>>2;for(k=0;k<4;k=k+1)if(ws[k])shadow[idx][k*8+:8]<=wd[k*8+:8];
    end else if(aw>=12'h400&&aw<12'h774)begin
     idx=(aw-12'h400)>>2;for(k=0;k<4;k=k+1)if(ws[k])lut_shadow[idx][k*8+:8]<=wd[k*8+:8];
    end else s_axi_bresp<=2;
   end
   if(config_pending&&config_safe)begin
    for(j=0;j<64;j=j+1)cfg[j]<=shadow[j];
    for(j=0;j<221;j=j+1)lut[j]<=lut_shadow[j];
    config_pending<=0;
   end
   if(s_axi_rvalid&&s_axi_rready)s_axi_rvalid<=0;
   if(s_axi_arvalid&&s_axi_arready)begin
    s_axi_rvalid<=1;s_axi_rresp<=0;s_axi_rdata<=0;
    if(s_axi_araddr==0)s_axi_rdata<=32'h31524550;
    else if(s_axi_araddr==4)s_axi_rdata<=seq;
    else if(s_axi_araddr==8)s_axi_rdata<={30'b0,snapshot_busy,config_pending};
    else if(s_axi_araddr>=12'h100&&s_axi_araddr<12'h200)s_axi_rdata<=cfg[(s_axi_araddr-12'h100)>>2];
    else if(s_axi_araddr>=12'h400&&s_axi_araddr<12'h774)s_axi_rdata<=lut[(s_axi_araddr-12'h400)>>2];
    else if(s_axi_araddr>=12'h800&&s_axi_araddr<12'he80)s_axi_rdata<=snapshot[(s_axi_araddr-12'h800)>>2];
    else s_axi_rresp<=2;
   end
   if(snapshot_start&&!snapshot_busy)begin
    seq<=seq+1;snapshot_busy<=1;copy_index<=0;
    for(j=0;j<32;j=j+1)snapshot[j]<=metadata[j*32+:32];
   end else if(snapshot_busy)begin
    for(j=0;j<12;j=j+1)snapshot[32+copy_index*12+j]<=object_data[(11-j)*32+:32];
    if(copy_index==31)begin snapshot_busy<=0;seq<=seq+1;end else copy_index<=copy_index+1;
   end
  end
 end
endmodule