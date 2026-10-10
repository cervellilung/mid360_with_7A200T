// ============================================================================
// 本文件从 fpga_ac880/sensor_perception_ar/rtl/integer_math.sv 原样搬入，行为未改。
// 原文件名：integer_math.sv
// 原路径：fpga_ac880/sensor_perception_ar/rtl/integer_math.sv
// ============================================================================
`timescale 1ns/1ps
// Sequential arithmetic shared by control-rate algorithms, never per pixel.
module unsigned_div64(input logic clk,rst,start,
 input logic [63:0] numerator,input logic [31:0] denominator,
 output logic busy,done,output logic [63:0] quotient,
 output logic [31:0] remainder);
 logic [63:0] bits,q; logic [32:0] rem; logic [31:0] den;
 logic [6:0] left; logic [32:0] trial;
 assign trial={rem[31:0],bits[63]};
 always_ff @(posedge clk) begin
  done<=0;
  if(rst) begin busy<=0; quotient<=0; remainder<=0; left<=0; end
  else if(start&&!busy) begin
   bits<=numerator; den<=denominator; rem<=0; q<=0; left<=64; busy<=1;
  end else if(busy) begin
   bits<=bits<<1;
   if(trial>={1'b0,den}) begin rem<=trial-den; q<={q[62:0],1'b1}; end
   else begin rem<=trial; q<={q[62:0],1'b0}; end
   left<=left-1;
   if(left==1) begin
    quotient<={q[62:0],trial>={1'b0,den}};
    remainder<=trial>={1'b0,den}?trial-den:trial;
    busy<=0; done<=1;
   end
  end
 end
endmodule

module integer_sqrt64(input logic clk,rst,start,input logic [63:0] value,
 output logic busy,done,output logic [31:0] root);
 logic [63:0] bits; logic [65:0] rem;
 logic [31:0] work; logic [5:0] left;
 wire [65:0] shifted={rem[63:0],bits[63:62]};
 wire [65:0] test_value={32'b0,work,2'b01};
 always_ff @(posedge clk) begin
  done<=0;
  if(rst) begin busy<=0;root<=0;left<=0; end
  else if(start&&!busy) begin bits<=value; rem<=0; work<=0;left<=32;busy<=1; end
  else if(busy) begin
   bits<=bits<<2;left<=left-1;
   rem<=shifted>=test_value?shifted-test_value:shifted;
   work<={work[30:0],shifted>=test_value};
   if(left==1) begin root<={work[30:0],shifted>=test_value};busy<=0;done<=1;end
  end
 end
endmodule