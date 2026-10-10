//============================================================================
// 来源：fpga_ac880/sensor_perception_ar/tests/tb_regs.sv，仅调整路径。
// 说明：从 7020（XC7Z020）工程原样搬入 ACX750 新工程，被测逻辑零改动。
//       注意：被测 perception_regs 的 s_axi_* 只是普通模块端口，由本 tb 直接
//       驱动，不依赖任何 Xilinx AXI IP，故可原样搬移。
//============================================================================
`timescale 1ns/1ps
module tb_regs;
 logic clk=0,rn=0;always #5 clk=~clk;
 logic [11:0] aw=0,ar=0;logic av=0,wv=0,bv,br=1,awr,wr,arv=0,arr,rv,rr=1;
 logic [31:0] wd=0,rd;logic [3:0] ws=15;logic [1:0] bp,rp;
 logic [2047:0] cfg;logic [7071:0] lut;logic pending,safe=0,start=0,busy;logic [4:0] index;
 logic [1023:0] meta=0;logic [383:0] obj;
 assign obj={32'hdeadbeef,320'd0,27'd0,index};
 perception_regs dut(.s_axi_aclk(clk),.s_axi_aresetn(rn),.s_axi_awaddr(aw),.s_axi_awprot(3'b0),.s_axi_awvalid(av),.s_axi_awready(awr),
 .s_axi_wdata(wd),.s_axi_wstrb(ws),.s_axi_wvalid(wv),.s_axi_wready(wr),.s_axi_bresp(bp),.s_axi_bvalid(bv),.s_axi_bready(br),
 .s_axi_araddr(ar),.s_axi_arprot(3'b0),.s_axi_arvalid(arv),.s_axi_arready(arr),.s_axi_rdata(rd),.s_axi_rresp(rp),.s_axi_rvalid(rv),.s_axi_rready(rr),
 .config_words(cfg),.lut_words(lut),.config_pending(pending),.config_safe(safe),.snapshot_start(start),.metadata(meta),.object_data(obj),.object_index(index),.snapshot_busy(busy));
 task write(input [11:0] addr,input [31:0] data);begin
  @(negedge clk);aw=addr;av=1;@(posedge clk);while(!awr)@(posedge clk);@(negedge clk);av=0;
  repeat(3)@(posedge clk);@(negedge clk);wd=data;wv=1;@(posedge clk);while(!wr)@(posedge clk);@(negedge clk);wv=0;
  wait(bv);if(bp!=0)$fatal(1,"write response");@(negedge clk);
 end endtask
 task read(input [11:0] addr,input [31:0] value);begin
  @(negedge clk);ar=addr;arv=1;@(posedge clk);while(!arr)@(posedge clk);@(negedge clk);arv=0;
  wait(rv);if(rd!==value||rp!=0)$fatal(1,"read %h got%h expected%h",addr,rd,value);@(negedge clk);
 end endtask
 initial begin
  #30;rn=1;read(0,32'h31524550);write(12'h110,321);read(12'h110,100);
  write(8,1);if(!pending)$fatal(1,"commit pending");safe=1;repeat(3)@(posedge clk);safe=0;read(12'h110,321);
  meta[0+:32]=32'h31524550;@(negedge clk);start=1;@(negedge clk);start=0;
  wait(busy);wait(!busy);read(4,2);read(12'h800,32'h31524550);read(12'he7c,31);
  $display("PASS regs independent AW/W, deferred commit and consistent snapshot");$finish;
 end
 initial begin #100000;$fatal(1,"regs timeout");end
endmodule