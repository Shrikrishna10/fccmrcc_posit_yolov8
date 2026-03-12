`include "posit_defines.svh"

// =============================================================================
// pdpu_array.sv — 4-PE systolic array, xsim-safe
// Avoids passing packed 2D arrays across module boundaries.
// Each PE accumulator is connected as a flat 32-bit signal.
// =============================================================================
module pdpu_array #(
    parameter POSIT_WIDTH = `POSIT_WIDTH,
    parameter ES          = `ES,
    parameter ACC_WIDTH   = `ACC_WIDTH,
    parameter N_PES       = `N_PES,
    parameter REGIME_MAX  = `REGIME_MAX
)(
    input  wire                               clk,
    input  wire                               rst,
    input  wire                               en,
    input  wire                               arr_load_weights,
    input  wire                               arr_acc_clear,
    input  wire                               arr_dot_done,
    input  wire [N_PES-1:0][POSIT_WIDTH-1:0] arr_weights,
    input  wire [POSIT_WIDTH-1:0]             arr_act_in,
    output wire [POSIT_WIDTH-1:0]             arr_result,
    output wire                               arr_result_valid
);

// ── Activation chain ─────────────────────────────────────────────────────────
wire [POSIT_WIDTH-1:0] act_chain [0:N_PES];
assign act_chain[0] = arr_act_in;

// ── PE accumulator outputs — flat individual wires (no packed 2D) ─────────────
wire [ACC_WIDTH-1:0] acc_out0, acc_out1, acc_out2, acc_out3;
wire                 acc_valid0, acc_valid1, acc_valid2, acc_valid3;

// ── Pack accumulators into 2D for reduction tree ──────────────────────────────
// Done here in the same module so no packed array crosses a port boundary
wire [N_PES-1:0][ACC_WIDTH-1:0] acc_packed;
assign acc_packed[0] = acc_out0;
assign acc_packed[1] = acc_out1;
assign acc_packed[2] = acc_out2;
assign acc_packed[3] = acc_out3;

// ── PE instances ─────────────────────────────────────────────────────────────
pdpu_pe #(.POSIT_WIDTH(POSIT_WIDTH),.ES(ES),.ACC_WIDTH(ACC_WIDTH),.REGIME_MAX(REGIME_MAX))
pe0 (.clk(clk),.rst(rst),.en(en),
     .pe_load_weight(arr_load_weights),.pe_acc_clear(arr_acc_clear),
     .pe_weight_in(arr_weights[0]),.pe_act_in(act_chain[0]),
     .pe_act_out(act_chain[1]),.pe_acc_out(acc_out0),.pe_acc_valid(acc_valid0));

pdpu_pe #(.POSIT_WIDTH(POSIT_WIDTH),.ES(ES),.ACC_WIDTH(ACC_WIDTH),.REGIME_MAX(REGIME_MAX))
pe1 (.clk(clk),.rst(rst),.en(en),
     .pe_load_weight(arr_load_weights),.pe_acc_clear(arr_acc_clear),
     .pe_weight_in(arr_weights[1]),.pe_act_in(act_chain[1]),
     .pe_act_out(act_chain[2]),.pe_acc_out(acc_out1),.pe_acc_valid(acc_valid1));

pdpu_pe #(.POSIT_WIDTH(POSIT_WIDTH),.ES(ES),.ACC_WIDTH(ACC_WIDTH),.REGIME_MAX(REGIME_MAX))
pe2 (.clk(clk),.rst(rst),.en(en),
     .pe_load_weight(arr_load_weights),.pe_acc_clear(arr_acc_clear),
     .pe_weight_in(arr_weights[2]),.pe_act_in(act_chain[2]),
     .pe_act_out(act_chain[3]),.pe_acc_out(acc_out2),.pe_acc_valid(acc_valid2));

pdpu_pe #(.POSIT_WIDTH(POSIT_WIDTH),.ES(ES),.ACC_WIDTH(ACC_WIDTH),.REGIME_MAX(REGIME_MAX))
pe3 (.clk(clk),.rst(rst),.en(en),
     .pe_load_weight(arr_load_weights),.pe_acc_clear(arr_acc_clear),
     .pe_weight_in(arr_weights[3]),.pe_act_in(act_chain[3]),
     .pe_act_out(act_chain[4]),.pe_acc_out(acc_out3),.pe_acc_valid(acc_valid3));

// ── Reduction tree ────────────────────────────────────────────────────────────
pdpu_reduction_tree #(.POSIT_WIDTH(POSIT_WIDTH),.ACC_WIDTH(ACC_WIDTH),.N_PES(N_PES))
u_tree (
    .clk(clk),.rst(rst),.en(en),
    .tree_start(arr_dot_done),
    .tree_acc_in(acc_packed),
    .tree_result(arr_result),
    .tree_result_valid(arr_result_valid)
);

endmodule
