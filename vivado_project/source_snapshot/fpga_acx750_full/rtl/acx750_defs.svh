//============================================================================
// acx750_defs.svh -- ACX750 (XC7A200T-FBG484-2) 工程全局常量
//
// 只放 `define，供各模块 `include；此文件里不允许出现 module/package。
// 引脚分配见 constraints/ 下的 XDC，本文件只描述"逻辑"常量。
//============================================================================
`ifndef ACX750_DEFS_SVH
`define ACX750_DEFS_SVH

//--------------------------------------------------------------------------
// 显示：800x480 RGB565（芯路恒 5 寸电容触摸屏）
// 面板时序取自厂商例程 ch24/ch57 的 disp_parameter_cfg.v：
//   H: Sync=128  Back=88  Active=800  Front=40   Total=1056
//   V: Sync=2    Back=25  Active=480  Front=2    Total=525
//   像素钟 = 33 MHz（由 pll 的 clk_out2 生成，相位 90°）
// 注意：AC880 那块屏是 976x528 / 31.016384 MHz，与这里完全不同，不得混用。
//--------------------------------------------------------------------------
`define DISP_WIDTH        800
`define DISP_HEIGHT       480
`define FRAME_PIXELS      (800*480)          // 384000
`define FRAME_BYTES       (800*480*2)        // 768000

//--------------------------------------------------------------------------
// 网络身份（单口以太网，PL 固定 192.168.1.50/24）
//   MID-360  雷达：192.168.1.20 -> 192.168.1.50:56301
//   树莓派 5 上位机：192.168.1.10，遥测收在 UDP 46000
//   树莓派 -> PL 下行配置：192.168.1.50:56300
//--------------------------------------------------------------------------
`define PL_MAC            48'h00_0a_35_01_fe_c0
`define PL_IP             32'hc0_a8_01_32    // 192.168.1.50
`define MID360_IP         32'hc0_a8_01_14    // 192.168.1.20
`define HOST_IP           32'hc0_a8_01_0a    // 192.168.1.10
`define RADAR_PORT        16'd56301          // PL 接收雷达点云
`define CONFIG_PORT       16'd56300          // PL 接收上位机下行
`define TELEM_PORT        16'd46000          // PL 向树莓派发 M3TL

// MID-360 上电后允许约 12 秒无点云，期间不得判为链路故障
`define RADAR_WARMUP_MS   12000

//--------------------------------------------------------------------------
// M3TL v1 遥测协议类型码（详见 docs/telemetry_protocol.md）
//--------------------------------------------------------------------------
`define M3TL_MAGIC4       32'h4c_54_33_4d    // "M3TL" 小端字节序
`define M3TL_VERSION      8'd1
`define M3TL_T_HEARTBEAT  8'd1
`define M3TL_T_CHASSIS    8'd2
`define M3TL_T_TARGETS    8'd3
`define M3TL_T_GRID       8'd5
`define M3TL_T_CAMERA     8'd6

// 栅格：55 行 x 60 列，位图按行优先、每字节 bit0 起
`define GRID_ROWS         55
`define GRID_COLS         60
`define GRID_CELLS        (55*60)            // 3300
`define GRID_BYTES        ((55*60+7)/8)      // 413

//--------------------------------------------------------------------------
// 感知/投影参数（与 fpga_ac880 的定点模型保持一致，迁移时不可改）
//--------------------------------------------------------------------------
`define GRID_CELL_MM      100                // 栅格边长 100 mm

//--------------------------------------------------------------------------
// 调试阶段号：上电默认值，运行中可用 UART 发送 '0'..'7' 切换
//--------------------------------------------------------------------------
`define STAGE_COLORBAR    3'd0
`define STAGE_DDR3_SELF   3'd1
`define STAGE_ETH_IMAGE   3'd2
`define STAGE_CAMERA      3'd3
`define STAGE_AR          3'd4
`define STAGE_TELEM       3'd5
`define STAGE_SPLIT       3'd6
`define STAGE_HUD_DEMO    3'd7

`endif // ACX750_DEFS_SVH