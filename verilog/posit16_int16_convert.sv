`timescale 1ns/1ps
`include "posit_defines.svh"

// ============================================================================
// posit16_to_int16.sv — Posit16 → INT16 fixed-point converter
//
// Used at the PL→PS boundary so ARM NEON can process 1×1 convs in INT16.
// Conversion: INT16 = round(posit_value × 2^FRAC_BITS)
//
// FRAC_BITS = 10 gives range [-32.0, +31.999] with 1/1024 resolution.
// Post-BN activations in YOLOv8n cluster in [-4, +8], well within range.
//
// RESOURCES: ~120 LUTs, 0 DSP, 0 BRAM (pure combinational with output reg)
// LATENCY:   1 cycle
// ============================================================================

module posit16_to_int16 #(
    parameter POSIT_WIDTH = `POSIT_WIDTH,
    parameter FRAC_BITS   = 10           // Q5.10 fixed-point
)(
    input  wire                   clk,
    input  wire                   rst,
    input  wire                   en,
    input  wire                   valid_in,
    input  wire [POSIT_WIDTH-1:0] posit_in,
    output reg  signed [15:0]     int16_out,
    output reg                    valid_out
);

// ── Decode Posit16 to sign + unsigned magnitude ──────────────────────────
wire is_zero = (posit_in == 16'h0000);
wire is_nar  = (posit_in == 16'h8000);
wire p_sign  = posit_in[15];

wire [14:0] body = p_sign ? (~posit_in[14:0] + 15'd1) : posit_in[14:0];
wire rbit = body[14];

// Regime run length
wire [3:0] run =
    (body[13] != rbit) ? 4'd1 :
    (body[12] != rbit) ? 4'd2 :
    (body[11] != rbit) ? 4'd3 :
    (body[10] != rbit) ? 4'd4 :
    (body[9]  != rbit) ? 4'd5 :
    (body[8]  != rbit) ? 4'd6 :
    (body[7]  != rbit) ? 4'd7 :
    (body[6]  != rbit) ? 4'd8 : 4'd9;

wire signed [4:0] k_s = rbit
    ? ($signed({1'b0, run}) - 5'sd1)
    : (-$signed({1'b0, run}));

wire [3:0] consumed = run + 4'd1;
wire exp_bit = (consumed <= 4'd14) ? body[14 - consumed] : 1'b0;

// Fraction extraction
wire [14:0] fshifted = body << (consumed + 4'd1);
wire [10:0] frac = fshifted[14:4];

// ── Compute fixed-point value ────────────────────────────────────────────
// Posit value = ±useed^k × 2^e × (1 + frac/2048)
// useed = 4 = 2^2, so scale = 2*k + e
// Fixed-point = (1.frac) << (scale + FRAC_BITS)
//             = {1, frac[10:0]} shifted by (2*k + e + FRAC_BITS - 11)
//
// We need to handle both left and right shifts.

wire signed [5:0] scale = $signed({k_s, exp_bit});  // 2*k + e
wire signed [6:0] shift_amount = $signed({1'b0, scale}) + FRAC_BITS - 11;

// 12-bit significand (1.fraction)
wire [11:0] significand = {1'b1, frac};

// Shift to produce fixed-point magnitude
// Max positive shift: 2*3 + 1 + 10 - 11 = 6 → significand << 6 = 18 bits max
// Max negative shift: 2*(-3) + 0 + 10 - 11 = -7 → significand >> 7
reg [21:0] shifted_mag;
always @(*) begin
    if (shift_amount >= 0) begin
        if (shift_amount > 7'd10)
            shifted_mag = 22'h3FFFFF;  // clamp to max
        else
            shifted_mag = {10'b0, significand} << shift_amount[3:0];
    end else begin
        if (shift_amount < -7'sd11)
            shifted_mag = 22'd0;       // too small, round to 0
        else
            shifted_mag = {10'b0, significand} >> (-shift_amount[3:0]);
    end
end

// Clamp to INT16 range
wire [15:0] magnitude_clamped = (shifted_mag > 22'd32767) ? 16'd32767 : shifted_mag[15:0];

// Apply sign
wire signed [15:0] result =
    is_zero ? 16'sd0 :
    is_nar  ? 16'sd0 :  // NaR → 0 (safe default for inference)
    p_sign  ? -$signed({1'b0, magnitude_clamped[14:0]}) :
              $signed({1'b0, magnitude_clamped[14:0]});

// ── Registered output ────────────────────────────────────────────────────
always_ff @(posedge clk) begin
    if (rst) begin
        int16_out <= 16'sd0;
        valid_out <= 1'b0;
    end else if (en) begin
        int16_out <= result;
        valid_out <= valid_in;
    end
end

endmodule


// ============================================================================
// int16_to_posit16.sv — INT16 fixed-point → Posit16 converter (reverse path)
//
// Used at PS→PL boundary when ARM result comes back to PL for next 3×3 conv.
// ============================================================================

module int16_to_posit16 #(
    parameter POSIT_WIDTH = `POSIT_WIDTH,
    parameter FRAC_BITS   = 10
)(
    input  wire                   clk,
    input  wire                   rst,
    input  wire                   en,
    input  wire                   valid_in,
    input  wire signed [15:0]     int16_in,
    output reg  [POSIT_WIDTH-1:0] posit_out,
    output reg                    valid_out
);

wire is_zero = (int16_in == 16'sd0);
wire in_sign = int16_in[15];
wire [15:0] magnitude = in_sign ? (-int16_in) : int16_in;

// Find leading 1 position (CLZ on 16-bit)
wire [3:0] lead =
    magnitude[15] ? 4'd15 : magnitude[14] ? 4'd14 :
    magnitude[13] ? 4'd13 : magnitude[12] ? 4'd12 :
    magnitude[11] ? 4'd11 : magnitude[10] ? 4'd10 :
    magnitude[9]  ? 4'd9  : magnitude[8]  ? 4'd8  :
    magnitude[7]  ? 4'd7  : magnitude[6]  ? 4'd6  :
    magnitude[5]  ? 4'd5  : magnitude[4]  ? 4'd4  :
    magnitude[3]  ? 4'd3  : magnitude[2]  ? 4'd2  :
    magnitude[1]  ? 4'd1  : 4'd0;

// Scale = lead - FRAC_BITS (since INT16 is Q5.10 with FRAC_BITS=10)
// k = scale / 2, e = scale % 2
wire signed [5:0] scale = $signed({2'b0, lead}) - FRAC_BITS;
wire signed [4:0] k_raw = scale[5:1];
wire              exp_bit = scale[0] ^ scale[5];  // handle negative mod

wire signed [3:0] k_clamped =
    (k_raw > 5'sd3)  ? 4'sd3  :
    (k_raw < -5'sd3) ? -4'sd3 :
     k_raw[3:0];

// Normalize magnitude and extract fraction
wire [15:0] norm = magnitude << (4'd15 - lead);
wire [10:0] frac = norm[14:4];

// Encode (same structure as reduction tree encoder)
wire k_neg = k_clamped[3];
wire [2:0] k_mag = k_neg ? (3'd0 - k_clamped[2:0]) : k_clamped[2:0];

reg [14:0] body;
always @(*) begin
    if (!k_neg) begin
        case (k_mag)
            3'd0: body = {1'b1, 1'b0, exp_bit, frac,        1'b0};
            3'd1: body = {2'b11, 1'b0, exp_bit, frac             };
            3'd2: body = {3'b111, 1'b0, exp_bit, frac[10:1]      };
            3'd3: body = {4'b1111, 1'b0, exp_bit, frac[10:2]     };
            default: body = {4'b1111, 1'b0, exp_bit, frac[10:2]};
        endcase
    end else begin
        case (k_mag)
            3'd1: body = {1'b0, 1'b1, exp_bit, frac,        1'b0};
            3'd2: body = {2'b00, 1'b1, exp_bit, frac             };
            3'd3: body = {3'b000, 1'b1, exp_bit, frac[10:1]      };
            default: body = {3'b000, 1'b1, 1'b0, exp_bit, frac[10:2]};
        endcase
    end
end

wire [15:0] encoded_pos = {1'b0, body};
wire [15:0] encoded_neg = ~encoded_pos + 16'd1;
wire [15:0] result = is_zero ? 16'h0000 :
                     in_sign ? encoded_neg : encoded_pos;

always_ff @(posedge clk) begin
    if (rst) begin
        posit_out <= 16'h0000;
        valid_out <= 1'b0;
    end else if (en) begin
        posit_out <= result;
        valid_out <= valid_in;
    end
end

endmodule
