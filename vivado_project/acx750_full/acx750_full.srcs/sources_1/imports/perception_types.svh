// ============================================================================
// 本文件从 fpga_ac880/sensor_perception_ar/rtl/perception_types.svh 原样搬入，行为未改。
// 原文件名：perception_types.svh
// 原路径：fpga_ac880/sensor_perception_ar/rtl/perception_types.svh
// ============================================================================
`ifndef PERCEPTION_TYPES
`define PERCEPTION_TYPES
typedef struct packed {
 logic [7:0] count;
 logic [15:0] points;
 logic signed [13:0] x0,x1,cx;
 logic signed [12:0] y0,y1,cy;
 logic signed [31:0] z0,z1,cz;
 logic [31:0] d2;
} cell_t;
typedef struct packed {
 logic [15:0] cells,points;
 logic signed [31:0] x0,y0,z0,x1,y1,z1;
 logic [63:0] d2;
 logic signed [31:0] cx,cy,cz;
} object_t;
`endif