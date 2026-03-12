// =============================================================================
// pdpu_approx_adder.v
// Exact Posit16 adder shell — interface FROZEN, internals swappable.
//
// Open Item #2: approximate variant TBD. This exact implementation unblocks
// pdpu_pe, pdpu_reduction_tree, and yolo_residual_add immediately.
// To swap: replace Steps 3-4 below with approximate logic. Steps 1-2 and 5-6
// (decode and encode) remain identical — do not touch them.
//
// LATENCY: 1 clock cycle
// SPECIAL CASES: a==0->b, b==0->a, NaR input->NaR
// =============================================================================
`include "posit_defines.svh"

module pdpu_approx_adder #(
    parameter POSIT_WIDTH = `POSIT_WIDTH,
    parameter ES          = `ES,
    parameter REGIME_MAX  = `REGIME_MAX
)(
    input  wire                   clk,
    input  wire                   rst,
    input  wire                   en,
    input  wire [POSIT_WIDTH-1:0] add_a,
    input  wire [POSIT_WIDTH-1:0] add_b,
    output reg  [POSIT_WIDTH-1:0] add_result,
    output reg                    add_valid
);

localparam FRAC_W   = POSIT_WIDTH - ES - 4; // 11 bits
localparam SIG_W    = FRAC_W + 1;           // 12 bits (hidden bit + frac)

// ---------------------------------------------------------------------------
// STEP 1 — DECODE A
// ---------------------------------------------------------------------------
wire        sign_a   = add_a[POSIT_WIDTH-1];
wire [POSIT_WIDTH-2:0] body_a = add_a[POSIT_WIDTH-2:0];
wire        rbit_a   = body_a[POSIT_WIDTH-2];
wire [3:0] m_a;
assign m_a = (body_a[13] != body_a[12]) ? 4'd1 :
             (body_a[12] != body_a[11]) ? 4'd2 :
             (body_a[11] != body_a[10]) ? 4'd3 :
             (body_a[10] != body_a[9])  ? 4'd4 :
             (body_a[9]  != body_a[8])  ? 4'd5 :
             (body_a[8]  != body_a[7])  ? 4'd6 :
             (body_a[7]  != body_a[6])  ? 4'd7 : 4'd8;
wire signed [3:0] k_a = rbit_a ? ($signed({1'b0,m_a})-4'd1) : (-$signed({1'b0,m_a}));
wire [POSIT_WIDTH-2:0] shift_a  = body_a << (m_a + 1);
wire [ES-1:0]    exp_a  = shift_a[POSIT_WIDTH-2 -: ES];
wire [FRAC_W-1:0] frac_a = shift_a[POSIT_WIDTH-2-ES -: FRAC_W];
// Scale: total exponent = k*2 + exp (for ES=1)
wire signed [4:0] scale_a = ($signed(k_a) <<< ES) + $signed({1'b0, exp_a});
wire [SIG_W-1:0] sig_a = {1'b1, frac_a}; // hidden bit prepended

// ---------------------------------------------------------------------------
// STEP 1 — DECODE B (identical)
// ---------------------------------------------------------------------------
wire        sign_b   = add_b[POSIT_WIDTH-1];
wire [POSIT_WIDTH-2:0] body_b = add_b[POSIT_WIDTH-2:0];
wire        rbit_b   = body_b[POSIT_WIDTH-2];
wire [3:0] m_b;
assign m_b = (body_b[13] != body_b[12]) ? 4'd1 :
             (body_b[12] != body_b[11]) ? 4'd2 :
             (body_b[11] != body_b[10]) ? 4'd3 :
             (body_b[10] != body_b[9])  ? 4'd4 :
             (body_b[9]  != body_b[8])  ? 4'd5 :
             (body_b[8]  != body_b[7])  ? 4'd6 :
             (body_b[7]  != body_b[6])  ? 4'd7 : 4'd8;
wire signed [3:0] k_b = rbit_b ? ($signed({1'b0,m_b})-4'd1) : (-$signed({1'b0,m_b}));
wire [POSIT_WIDTH-2:0] shift_b  = body_b << (m_b + 1);
wire [ES-1:0]    exp_b  = shift_b[POSIT_WIDTH-2 -: ES];
wire [FRAC_W-1:0] frac_b = shift_b[POSIT_WIDTH-2-ES -: FRAC_W];
wire signed [4:0] scale_b = ($signed(k_b) <<< ES) + $signed({1'b0, exp_b});
wire [SIG_W-1:0] sig_b = {1'b1, frac_b};

// ---------------------------------------------------------------------------
// STEP 2 — ALIGN: shift smaller operand right by |scale_diff|
// ---------------------------------------------------------------------------
wire signed [4:0] scale_diff = scale_a - scale_b;
wire        a_larger   = (scale_diff >= 0);
wire [4:0]  shift_amt  = a_larger ? scale_diff[4:0] : (-scale_diff[4:0]);
// Aligned significands (guard bit appended for rounding)
wire [SIG_W+7:0] sig_hi  = {sig_a, 8'b0};  // larger operand, no shift
wire [SIG_W+7:0] sig_lo  = {sig_b, 8'b0} >> shift_amt; // smaller, shifted
wire [SIG_W+7:0] aligned_a = a_larger ? sig_hi : sig_lo;
wire [SIG_W+7:0] aligned_b = a_larger ? sig_lo : sig_hi;
wire signed [4:0] scale_r  = a_larger ? scale_a : scale_b;

// ---------------------------------------------------------------------------
// STEP 3 — ADD/SUBTRACT (exact — replace with approx here when Open Item #2 resolved)
// ---------------------------------------------------------------------------
wire        same_sign = (sign_a == sign_b);
wire [SIG_W+8:0] sum_raw = same_sign
    ? ({1'b0, aligned_a} + {1'b0, aligned_b})
    : ({1'b0, aligned_a} - {1'b0, aligned_b});
wire        result_sign = same_sign ? sign_a : (a_larger ? sign_a : sign_b);
wire [SIG_W+8:0] sum_mag = sum_raw[SIG_W+8] ? (~sum_raw + 1) : sum_raw; // ensure positive

// ---------------------------------------------------------------------------
// STEP 4 — NORMALISE (find leading 1 via CLZ, adjust scale)
// ---------------------------------------------------------------------------
// Find position of leading 1 in sum_mag (SIG_W+9 bits wide)
wire [4:0] leading_zeros;
// Priority encoder over top bits of sum_mag
assign leading_zeros =
    sum_mag[SIG_W+8] ? 5'd0 :
    sum_mag[SIG_W+7] ? 5'd1 :
    sum_mag[SIG_W+6] ? 5'd2 :
    sum_mag[SIG_W+5] ? 5'd3 :
    sum_mag[SIG_W+4] ? 5'd4 :
    sum_mag[SIG_W+3] ? 5'd5 :
    sum_mag[SIG_W+2] ? 5'd6 :
    sum_mag[SIG_W+1] ? 5'd7 :
    sum_mag[SIG_W]   ? 5'd8 :
    5'd9; // zero result

wire [SIG_W+8:0] sum_norm = sum_mag << leading_zeros; // align leading 1 to MSB

localparam [4:0] MSB_POS = (SIG_W + 8);
wire signed [4:0] scale_norm = scale_r + $signed({1'b0, MSB_POS}) - $signed({1'b0,leading_zeros}) - 5'd1;

wire [FRAC_W-1:0] frac_r = sum_norm[SIG_W+7 -: FRAC_W]; // extract fraction (drop hidden bit)
wire [ES-1:0]     exp_r  = scale_norm[0 +: ES];
wire signed [3:0] k_r_raw = scale_norm[ES +: 4];
wire signed [3:0] k_r =
    (k_r_raw >  $signed(REGIME_MAX[3:0])) ?  $signed(REGIME_MAX[3:0]) :
    (k_r_raw < -$signed(REGIME_MAX[3:0])) ? -$signed(REGIME_MAX[3:0]) :
     k_r_raw;

// ---------------------------------------------------------------------------
// STEP 5 — ENCODE back to Posit16
// (Same encode pattern as mitchell_mult Stage 4)
// ---------------------------------------------------------------------------
wire        k_neg_r  = k_r[3];
wire [2:0]  k_mag_r  = k_neg_r ? (~k_r[2:0] + 3'd1) : k_r[2:0];
wire [14:0] regime_r = k_neg_r
    ? ( ~({15{1'b0}} | ({15{1'b1}} >> k_mag_r)) )
    :   ({15{1'b1}} << (14 - k_mag_r));
wire [14:0] body_r   = regime_r
                     | (exp_r  << (13 - k_mag_r - ES))
                     | (frac_r >> (k_mag_r + ES + 2));

wire [POSIT_WIDTH-1:0] result_encoded = result_sign
    ? (~{1'b0, body_r} + 1'b1)
    :  {1'b0, body_r};

// ---------------------------------------------------------------------------
// SPECIAL CASES
// ---------------------------------------------------------------------------
wire is_zero_a = (add_a == `POSIT_ZERO);
wire is_zero_b = (add_b == `POSIT_ZERO);
wire is_nar_a  = (add_a == `POSIT_NAR);
wire is_nar_b  = (add_b == `POSIT_NAR);
wire is_zero_r = (sum_mag == 0);

wire [POSIT_WIDTH-1:0] add_result_next =
    (is_nar_a  || is_nar_b) ? `POSIT_NAR  :
    (is_zero_a)             ? add_b        :
    (is_zero_b)             ? add_a        :
    (is_zero_r)             ? `POSIT_ZERO  :
    result_encoded;

// ---------------------------------------------------------------------------
// REGISTERED OUTPUT
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    if (rst) begin
        add_result <= `POSIT_ZERO;
        add_valid  <= 1'b0;
    end else if (en) begin
        add_result <= add_result_next;
        add_valid  <= 1'b1;
    end
end

endmodule
