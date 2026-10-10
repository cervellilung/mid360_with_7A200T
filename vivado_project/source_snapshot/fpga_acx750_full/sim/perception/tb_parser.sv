//============================================================================
// 来源：fpga_ac880/sensor_perception_ar/tests/tb_parser.sv，仅调整路径。
// 说明：从 7020（XC7Z020）工程原样搬入 ACX750 新工程，被测逻辑零改动。
//       本 tb 通过 +input=<文件> 读入一帧报文（hex 文本），由驱动生成。
//============================================================================
`timescale 1ns/1ps
module tb_parser;
 logic clk=0,rst=1;always #5 clk=~clk;
 logic [7:0] sd;logic sv=0,sl=0,sr,pv,pr=1;
 logic signed [31:0] x,y,z;logic [63:0] ts;logic [31:0] bad,good,nocrc,scan_index;
 integer fd,n,rc,i,seen=0;reg [7:0] bytes[0:2047];reg [1023:0] path;
 mid360_points dut(.clk(clk),.rst(rst),.s_data(sd),.s_valid(sv),.s_last(sl),.s_ready(sr),
  .point_valid(pv),.point_ready(pr),.x(x),.y(y),.z(z),.timestamp_ns(ts),.scan_index(scan_index),.bad_packets(bad),.good_packets(good),.crc_unavailable(nocrc));
 always @(posedge clk)if(pv&&pr)begin
  if(x!==1000+(seen%2)*100||y!==-200||z!==300||ts!==64'd1000000000||scan_index!==32'd10)$fatal(1,"parser xyz %d %d %d",x,y,z);
  seen=seen+1;
 end
 task send;begin for(i=0;i<n;i=i+1)begin
  @(negedge clk);sv=1;sd=bytes[i];sl=i==n-1;
  @(posedge clk);while(!sr)@(posedge clk);
  @(negedge clk);sv=0;
 end wait(sr);repeat(3)@(posedge clk);end endtask
 initial begin
  if(!$value$plusargs("input=%s",path))$fatal(1,"missing input");
  fd=$fopen(path,"r");rc=$fscanf(fd,"%d",n);for(i=0;i<n;i=i+1)rc=$fscanf(fd,"%h",bytes[i]);$fclose(fd);
  #30;rst=0;send();if(seen!=2||good!=1||bad!=0)$fatal(1,"valid packet counts");
  bytes[n-1]=bytes[n-1]^1;send();if(bad!=1||seen!=2)$fatal(1,"CRC rejection");
  bytes[n-1]=bytes[n-1]^1;bytes[24]=0;bytes[25]=0;bytes[26]=0;bytes[27]=0;
  send();if(good!=2||seen!=4||nocrc!=1)$fatal(1,"zero CRC firmware compatibility");
  bytes[5]=3;send();if(bad!=2||seen!=4)$fatal(1,"structural point count rejection");
  $display("PASS parser strict CRC and signed Cartesian points");$finish;
 end
 initial begin #1000000;$fatal(1,"parser timeout");end
endmodule