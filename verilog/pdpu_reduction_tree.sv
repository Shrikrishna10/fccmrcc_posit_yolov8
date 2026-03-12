`timescale 1ns/1ps
`include "posit_defines.svh"

// ============================================================================
// pdpu_reduction_tree.sv — Parameterized binary adder tree + integer-to-Posit16
//
// CHANGES FROM ORIGINAL:
//   - Hardcoded 4-PE adder tree replaced with generate-based log2(N) tree
//   - Works for any power-of-2 N_PES: 2, 4, 8, 16, 32, 64
//   - CLZ, k/e extraction, and Posit16 encode are UNCHANGED
// ============================================================================

module pdpu_reduction_tree #(
    parameter POSIT_WIDTH = `POSIT_WIDTH,
    parameter ACC_WIDTH   = `ACC_WIDTH,
    parameter N_PES       = `N_PES
)(
    input  wire                             clk,
    input  wire                             rst,
    input  wire                             en,
    input  wire                             tree_start,
    input  wire [N_PES-1:0][ACC_WIDTH-1:0] tree_acc_in,
    output reg  [POSIT_WIDTH-1:0]          tree_result,
    output reg                              tree_result_valid
);

// ── Parameterized binary adder tree ───────────────────────────────────────
// For N_PES inputs, we need log2(N_PES) levels.
// Level 0: N_PES/2 adders → N_PES/2 partial sums
// Level 1: N_PES/4 adders → N_PES/4 partial sums
// ...
// Level log2(N)-1: 1 adder → 1 final sum
//
// Uses a flat array indexed by level and position.
// Total nodes = N_PES - 1 (complete binary tree).

// clog2 function for parameter computation
function automatic integer clog2(input integer val);
    integer i;
    begin
        clog2 = 0;
        for (i = val - 1; i > 0; i = i >> 1)
            clog2 = clog2 + 1;
    end
endfunction

localparam LEVELS = clog2(N_PES);

// Tree storage: level L has N_PES >> (L+1) partial sums
// We use a 2D array: tree_node[level][index]
// Max nodes at any level = N_PES/2
wire signed [ACC_WIDTH-1:0] tree_node [0:LEVELS-1][0:(N_PES/2)-1];

// Level 0: add adjacent pairs from input
genvar gi;
generate
    for (gi = 0; gi < N_PES/2; gi = gi + 1) begin : gen_level0
        assign tree_node[0][gi] = $signed(tree_acc_in[2*gi])
                                + $signed(tree_acc_in[2*gi + 1]);
    end
endgenerate

// Levels 1 to LEVELS-1: add adjacent pairs from previous level
genvar gl, gj;
generate
    for (gl = 1; gl < LEVELS; gl = gl + 1) begin : gen_levels
        for (gj = 0; gj < (N_PES >> (gl+1)); gj = gj + 1) begin : gen_pairs
            assign tree_node[gl][gj] = tree_node[gl-1][2*gj]
                                     + tree_node[gl-1][2*gj + 1];
        end
    end
endgenerate

// Final sum is at tree_node[LEVELS-1][0]
wire signed [ACC_WIDTH-1:0] wide_sum = tree_node[LEVELS-1][0];

// ── Sign / magnitude (UNCHANGED) ─────────────────────────────────────────
wire        sum_sign = wide_sum[31];
wire [31:0] sum_mag  = sum_sign ? (~wide_sum + 32'd1) : wide_sum;

// ── CLZ (UNCHANGED) ──────────────────────────────────────────────────────
wire [4:0] clz =
    sum_mag[31] ? 5'd0  : sum_mag[30] ? 5'd1  : sum_mag[29] ? 5'd2  :
    sum_mag[28] ? 5'd3  : sum_mag[27] ? 5'd4  : sum_mag[26] ? 5'd5  :
    sum_mag[25] ? 5'd6  : sum_mag[24] ? 5'd7  : sum_mag[23] ? 5'd8  :
    sum_mag[22] ? 5'd9  : sum_mag[21] ? 5'd10 : sum_mag[20] ? 5'd11 :
    sum_mag[19] ? 5'd12 : sum_mag[18] ? 5'd13 : sum_mag[17] ? 5'd14 :
    sum_mag[16] ? 5'd15 : sum_mag[15] ? 5'd16 : sum_mag[14] ? 5'd17 :
    sum_mag[13] ? 5'd18 : sum_mag[12] ? 5'd19 : sum_mag[11] ? 5'd20 :
    sum_mag[10] ? 5'd21 : sum_mag[9]  ? 5'd22 : sum_mag[8]  ? 5'd23 :
    sum_mag[7]  ? 5'd24 : sum_mag[6]  ? 5'd25 : sum_mag[5]  ? 5'd26 :
    sum_mag[4]  ? 5'd27 : sum_mag[3]  ? 5'd28 : sum_mag[2]  ? 5'd29 :
    sum_mag[1]  ? 5'd30 : 5'd31;

wire [4:0] lead_pos = 5'd31 - clz;

// ── k and e from lead_pos (UNCHANGED) ────────────────────────────────────
wire [3:0] k_unsigned = lead_pos[4:1];
wire [3:0] k_clamped  = (k_unsigned > 4'd3) ? 4'd3 : k_unsigned;
wire       exp_r      = lead_pos[0];

// ── Normalise and extract fraction (UNCHANGED) ───────────────────────────
wire [31:0] norm_mag = sum_mag << clz;
wire [10:0] frac_r   = norm_mag[30:20];

// ── Encode Posit16 body (UNCHANGED) ──────────────────────────────────────
reg [14:0] body_pos;
always @(*) begin
    case (k_clamped)
        4'd0: body_pos = {1'b1, 1'b0, exp_r, frac_r,     1'b0};
        4'd1: body_pos = {2'b11, 1'b0, exp_r, frac_r               };
        4'd2: body_pos = {3'b111, 1'b0, exp_r, frac_r[10:1]        };
        4'd3: body_pos = {4'b1111, 1'b0, exp_r, frac_r[10:2]       };
        default: body_pos = {4'b1111, 1'b0, exp_r, frac_r[10:2]};
    endcase
end

wire [15:0] encoded_pos = {1'b0, body_pos};
wire [15:0] encoded_neg = ~encoded_pos + 16'd1;

wire [15:0] rounded_result =
    (wide_sum == 32'd0) ? 16'h0000 :
    sum_sign            ? encoded_neg :
                          encoded_pos;

// ── Registered output (UNCHANGED) ────────────────────────────────────────
always_ff @(posedge clk) begin
    if (rst) begin
        tree_result       <= 16'h0000;
        tree_result_valid <= 1'b0;
    end else if (en) begin
        tree_result_valid <= 1'b0;
        if (tree_start) begin
            tree_result       <= rounded_result;
            tree_result_valid <= 1'b1;
        end
    end
end

endmodule
