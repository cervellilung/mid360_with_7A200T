//============================================================================
// acx750_led_beat -- 心跳/呼吸指示
//
// beat_pulse  : 4 Hz 单周期脉冲，用于看板卡是否还在跑
// breath      : PWM 呼吸，用于 1 颗 LED 做"活着"指示
//============================================================================
`timescale 1ns/1ps

module acx750_led_beat #(
  parameter int unsigned SYS_HZ = 100_000_000,
  parameter int unsigned BEAT_HZ = 4
)(
  input  logic clk,
  input  logic rst_n,
  output logic beat_pulse,
  output logic breath
);

  localparam int unsigned BEAT_DIV = SYS_HZ / BEAT_HZ;

  logic [31:0] cnt;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt <= '0;
      beat_pulse <= 1'b0;
    end else if (cnt == BEAT_DIV - 1) begin
      cnt <= '0;
      beat_pulse <= 1'b1;
    end else begin
      cnt <= cnt + 1'b1;
      beat_pulse <= 1'b0;
    end
  end

  // 呼吸：用计数高位做占空比可变的 PWM，肉眼可见但不刺眼
  logic [16:0] pwm_cnt;
  logic [16:0] duty;
  logic        up;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pwm_cnt <= '0;
      duty    <= '0;
      up      <= 1'b1;
    end else begin
      pwm_cnt <= pwm_cnt + 1'b1;
      if (pwm_cnt == 17'h1FFFF) begin
        if (up) begin
          if (duty >= 17'h0FF00) up <= 1'b0;
          else                   duty <= duty + 17'h00080;
        end else begin
          if (duty <= 17'h00080) up <= 1'b1;
          else                   duty <= duty - 17'h00080;
        end
      end
    end
  end

  assign breath = (pwm_cnt < {1'b0, duty});

endmodule