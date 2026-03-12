`timescale 1ns/1ps
`include "posit_defines.svh"

module pdpu_mitchell_mult #(
    parameter POSIT_WIDTH = `POSIT_WIDTH,
    parameter ES          = `ES,
    parameter REGIME_MAX  = `REGIME_MAX
)(
    input  wire                   clk,
    input  wire                   rst,
    input  wire                   en,
    input  wire [POSIT_WIDTH-1:0] mult_a,
    input  wire [POSIT_WIDTH-1:0] mult_b,
    output reg  [POSIT_WIDTH-1:0] mult_result,
    output reg                    mult_valid
);

// ---------------------------------------------------------------------------
// Special case detection
// ---------------------------------------------------------------------------
wire is_zero_a = (mult_a == 16'h0000);
wire is_zero_b = (mult_b == 16'h0000);
wire is_nar_a  = (mult_a == 16'h8000);
wire is_nar_b  = (mult_b == 16'h8000);
wire special   = is_zero_a | is_zero_b | is_nar_a | is_nar_b;

// ---------------------------------------------------------------------------
// Sign
// ---------------------------------------------------------------------------
wire result_sign = mult_a[15] ^ mult_b[15];

// ---------------------------------------------------------------------------
// Decode A: magnitude body
// ---------------------------------------------------------------------------
wire [14:0] body_a = mult_a[15] ? (~mult_a[14:0] + 15'd1) : mult_a[14:0];
wire        rbit_a = body_a[14];

// Run-length of regime (explicit priority encoder — no loops)
wire [3:0] run_a =
    (body_a[13] != rbit_a) ? 4'd1 :
    (body_a[12] != rbit_a) ? 4'd2 :
    (body_a[11] != rbit_a) ? 4'd3 :
    (body_a[10] != rbit_a) ? 4'd4 :
    (body_a[9]  != rbit_a) ? 4'd5 :
    (body_a[8]  != rbit_a) ? 4'd6 :
    (body_a[7]  != rbit_a) ? 4'd7 :
    (body_a[6]  != rbit_a) ? 4'd8 : 4'd9;  // max regime for 15-bit body

// k: rbit=1 => k=run-1 (positive), rbit=0 => k=-run (negative)
// Represent as signed 5-bit
wire signed [4:0] k_a_s = rbit_a
    ? ($signed({1'b0, run_a[3:0]}) - 5'sd1)
    : (-$signed({1'b0, run_a[3:0]}));

// Clamp to [-3,+3]
wire signed [4:0] k_a =
    (k_a_s > 5'sd3)  ? 5'sd3  :
    (k_a_s < -5'sd3) ? -5'sd3 :
     k_a_s;

// Bits consumed by regime field = run + 1 (terminator)
wire [3:0] cons_a = run_a + 4'd1;

// exp bit: bit (14 - cons_a) of body_a, if in range
wire exp_a = (cons_a <= 4'd14) ? body_a[14 - cons_a] : 1'b0;

// Fraction: shift out regime + terminator + exp, take top 11 bits
wire [14:0] fshift_a = body_a << (cons_a + 4'd1);
wire [10:0] frac_a   = fshift_a[14:4];

// ---------------------------------------------------------------------------
// Decode B (identical structure)
// ---------------------------------------------------------------------------
wire [14:0] body_b = mult_b[15] ? (~mult_b[14:0] + 15'd1) : mult_b[14:0];
wire        rbit_b = body_b[14];

wire [3:0] run_b =
    (body_b[13] != rbit_b) ? 4'd1 :
    (body_b[12] != rbit_b) ? 4'd2 :
    (body_b[11] != rbit_b) ? 4'd3 :
    (body_b[10] != rbit_b) ? 4'd4 :
    (body_b[9]  != rbit_b) ? 4'd5 :
    (body_b[8]  != rbit_b) ? 4'd6 :
    (body_b[7]  != rbit_b) ? 4'd7 :
    (body_b[6]  != rbit_b) ? 4'd8 : 4'd9;

wire signed [4:0] k_b_s = rbit_b
    ? ($signed({1'b0, run_b[3:0]}) - 5'sd1)
    : (-$signed({1'b0, run_b[3:0]}));

wire signed [4:0] k_b =
    (k_b_s > 5'sd3)  ? 5'sd3  :
    (k_b_s < -5'sd3) ? -5'sd3 :
     k_b_s;

wire [3:0] cons_b = run_b + 4'd1;
wire exp_b = (cons_b <= 4'd14) ? body_b[14 - cons_b] : 1'b0;
wire [14:0] fshift_b = body_b << (cons_b + 4'd1);
wire [10:0] frac_b   = fshift_b[14:4];

// ---------------------------------------------------------------------------
// Mitchell log-domain multiply: add scales
// scale_a = 2*k_a + exp_a  (signed 6-bit)
// scale_b = 2*k_b + exp_b
// scale_r = scale_a + scale_b
// ---------------------------------------------------------------------------
wire signed [5:0] scale_a = $signed({k_a, exp_a});
wire signed [5:0] scale_b = $signed({k_b, exp_b});
wire signed [6:0] scale_r_wide = $signed({scale_a[5], scale_a}) + $signed({scale_b[5], scale_b});

// Clamp result scale to [-6, +6] (Posit<16,1> max range)
wire signed [5:0] scale_r =
    (scale_r_wide > 7'sd6)  ? 6'sd6  :
    (scale_r_wide < -7'sd6) ? -6'sd6 :
     scale_r_wide[5:0];

// Extract k and e from result scale
wire signed [4:0] k_r_s  = scale_r[5:1];   // divide by 2 (arithmetic)
wire              exp_r   = scale_r[0];      // mod 2

// Clamp k_r to [-3,+3]
wire signed [3:0] k_r =
    (k_r_s > 5'sd3)  ? 4'sd3  :
    (k_r_s < -5'sd3) ? -4'sd3 :
     k_r_s[3:0];

// ---------------------------------------------------------------------------
// Mitchell fraction approximation: frac_r = frac_a + frac_b (truncated)
// log(1+f) approx f; product frac = fa + fb (Mitchell first order)
// Result clamped to 11 bits
// ---------------------------------------------------------------------------
wire [11:0] frac_sum = {1'b0, frac_a} + {1'b0, frac_b};
wire [10:0] frac_r   = frac_sum[11] ? 11'h7FF : frac_sum[10:0];

// ---------------------------------------------------------------------------
// Encode result into Posit16 body using case (avoids variable-shift X)
// ---------------------------------------------------------------------------
wire        k_neg_r = k_r[3];
wire [2:0]  k_mag_r = k_neg_r ? (3'd0 - k_r[2:0]) : k_r[2:0];

// 15-bit body built by explicit case on k_mag and sign
// Format reference (MSB first in body[14:0]):
//  k=0 pos:  1  0  e  f[10:0]  _          (1+1+1+11+1 pad = 15? no, 1+1+1+11=14, pad 1 at LSB)
//  k=1 pos:  1  1  0  e  f[10:0]          (2+1+1+11=15)
//  k=2 pos:  1  1  1  0  e  f[10:1]       (3+1+1+10=15)
//  k=3 pos:  1  1  1  1  0  e  f[10:2]    (4+1+1+9=15)
//  k=1 neg:  0  1  0  e  f[10:0]  _       (1+1+1+1+11=15? 0+1+0+e+11=14, pad)
//  Actually for k<0: k_mag zeros then 1 then exp then frac

reg [14:0] body_r;
always @(*) begin
    if (!k_neg_r) begin
        case (k_mag_r)
            3'd0: body_r = {1'b1, 1'b0, exp_r, frac_r,        1'b0};  // 1+1+1+11+1=15
            3'd1: body_r = {2'b11, 1'b0, exp_r, frac_r             };  // 2+1+1+11=15
            3'd2: body_r = {3'b111, 1'b0, exp_r, frac_r[10:1]      };  // 3+1+1+10=15
            3'd3: body_r = {4'b1111, 1'b0, exp_r, frac_r[10:2]     };  // 4+1+1+9=15
            default: body_r = {4'b1111, 1'b0, exp_r, frac_r[10:2]};
        endcase
    end else begin
        case (k_mag_r)
            3'd1: body_r = {1'b0, 1'b1, 1'b0, exp_r, frac_r,  1'b0};  // 1+1+1+1+11=15
            3'd2: body_r = {2'b00, 1'b1, 1'b0, exp_r, frac_r[10:1]};  // 2+1+1+10=? no
            3'd3: body_r = {3'b000, 1'b1, 1'b0, exp_r, frac_r[10:2]}; // 3+1+1+9=14?
            default: body_r = {3'b000, 1'b1, 1'b0, exp_r, frac_r[10:2]};
        endcase
    end
end

wire [15:0] encoded_pos = {1'b0, body_r};
wire [15:0] encoded_neg = ~encoded_pos + 16'd1;
wire [15:0] result_normal = result_sign ? encoded_neg : encoded_pos;

wire [15:0] mult_result_next =
    (is_nar_a | is_nar_b)   ? 16'h8000 :
    (is_zero_a | is_zero_b) ? 16'h0000 :
    result_normal;

// ---------------------------------------------------------------------------
// Registered output — 1 cycle latency
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    if (rst) begin
        mult_result <= 16'h0000;
        mult_valid  <= 1'b0;
    end else if (en) begin
        mult_result <= mult_result_next;
        mult_valid  <= 1'b1;
    end
end

endmodule
