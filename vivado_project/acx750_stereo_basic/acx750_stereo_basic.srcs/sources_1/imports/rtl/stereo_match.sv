`timescale 1ns/1ps
// Eight shared popcount lanes search 64 disparities in 24 processing cycles.
// Right descriptors advance once per pixel; history is invalid at each row start.
// Input must be raster ordered, rectified, and contain both descriptors at identical coordinates.
module stereo_match #(parameter integer WIDTH=320,HEIGHT=240,DISPARITIES=64,LANES=8)(
 input logic clk,rst,input logic in_valid,output logic in_ready,
 input logic [23:0] left,right,input logic left_valid,right_valid,
 input logic sof,input logic [31:0] frame_id,input logic [63:0] stamp_us,
 input logic [5:0] max_cost,uniqueness,
 output logic out_valid,input logic out_ready,output logic matched,
 output logic [6:0] disparity,output logic [5:0] cost,
 output logic [$clog2(WIDTH)-1:0] x,output logic [$clog2(HEIGHT)-1:0] y,
 output logic [31:0] out_frame_id,output logic [63:0] out_stamp_us);
 localparam integer XW=$clog2(WIDTH),YW=$clog2(HEIGHT),GW=($clog2(DISPARITIES/LANES)<1?1:$clog2(DISPARITIES/LANES));
 logic [23:0] history[0:DISPARITIES-1];logic [DISPARITIES-1:0] hv;
 logic [23:0] lhold;logic lv;logic [XW-1:0] col,cx;logic [YW-1:0] row,cy;
 logic [GW-1:0] group_index;logic [2:0] state;
 logic [5:0] max_hold,unique_hold;
 logic [5:0] best,second,group_best,group_second;
 logic [6:0] best_d,group_d;logic [5:0] scores[0:LANES-1];
 function automatic [5:0] pop24(input logic [23:0] v);
  logic [2:0] p[0:5];logic [3:0] a,b,c;
  begin
   for(integer k=0;k<6;k=k+1)p[k]={2'b0,v[k*4]}+{2'b0,v[k*4+1]}+{2'b0,v[k*4+2]}+{2'b0,v[k*4+3]};
   a={1'b0,p[0]}+{1'b0,p[1]};b={1'b0,p[2]}+{1'b0,p[3]};c={1'b0,p[4]}+{1'b0,p[5]};
   pop24={2'b0,a}+{2'b0,b}+{2'b0,c};
  end
 endfunction
 assign in_ready=state==0;
 logic [18:0] leaves[0:LANES-1],pairs[0:LANES/2-1],pairs_q[0:LANES/2-1],quads[0:LANES/4-1],root_node,merged;
 function automatic [18:0] merge2(input logic [18:0] a,b);
  logic [5:0] m,s;logic [6:0] d;
  begin
   if(a[18:13]<=b[18:13])begin m=a[18:13];d=a[6:0];s=a[12:7]<b[18:13]?a[12:7]:b[18:13];end
   else begin m=b[18:13];d=b[6:0];s=b[12:7]<a[18:13]?b[12:7]:a[18:13];end
   merge2={m,s,d};
  end
 endfunction
 initial if(LANES!=8||DISPARITIES<8||DISPARITIES%8!=0)$error("stereo_match requires eight lanes and a multiple of eight disparities");
 // Registered cost stage, then balanced three-level comparator tree and merge.
 always_comb begin
  for(integer k=0;k<LANES;k=k+1)leaves[k]={scores[k],6'd63,7'(group_index*LANES+k)};
  for(integer k=0;k<LANES/2;k=k+1)pairs[k]=merge2(leaves[2*k],leaves[2*k+1]);
  for(integer k=0;k<LANES/4;k=k+1)quads[k]=merge2(pairs_q[2*k],pairs_q[2*k+1]);
  root_node=merge2(quads[0],quads[1]);merged=merge2({best,second,best_d},root_node);
  group_best=merged[18:13];group_second=merged[12:7];group_d=merged[6:0];
 end
 always_ff @(posedge clk)begin
  if(rst)begin state<=0;out_valid<=0;col<=0;row<=0;hv<=0;end
  else case(state)
   0:if(in_valid)begin
    cx<=sof?'0:col;cy<=sof?'0:row;lhold<=left;lv<=left_valid;
    out_frame_id<=frame_id;out_stamp_us<=stamp_us;
    max_hold<=max_cost;unique_hold<=uniqueness;
    history[0]<=right;
    for(integer k=1;k<DISPARITIES;k=k+1)history[k]<=history[k-1];
    hv<=((sof||col==0)?'0:hv)<<1;hv[0]<=right_valid;
    if((sof?0:col)==WIDTH-1)begin col<=0;row<=(sof?0:row)+1'b1;end
    else begin col<=(sof?0:col)+1'b1;if(sof)row<=0;end
    best<=63;second<=63;best_d<=0;group_index<=0;state<=1;
   end
   1:begin
    for(integer k=0;k<LANES;k=k+1)
     scores[k]<=(hv[group_index*LANES+k]&&lv&&cx>=group_index*LANES+k+4)?pop24(lhold^history[group_index*LANES+k]):6'd63;
    state<=2;
   end
   2:begin
    for(integer k=0;k<LANES/2;k=k+1)pairs_q[k]<=pairs[k];
    state<=4;
   end
   4:begin
    best<=group_best;second<=group_second;best_d<=group_d;
    if(group_index==DISPARITIES/LANES-1)begin
     cost<=group_best;disparity<=group_d;
     x<=cx>=2?cx-2:0;y<=cy>=2?cy-2:0;state<=5;
    end else begin group_index<=group_index+1'b1;state<=1;end
   end
   5:begin
    matched<=best<=max_hold&&second>best&&({1'b0,second}-{1'b0,best})>=unique_hold&&best_d!=0;
    out_valid<=1;state<=3;
   end
   3:if(out_ready)begin out_valid<=0;state<=0;end
   default:state<=0;
  endcase
 end
endmodule
