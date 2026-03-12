`timescale 1ns/1ps
`include "posit_defines.svh"

// ============================================================================
// pdpu_array_banked.sv — Multi-bank systolic array for output parallelism
//
// Architecture:
//   N_BANKS independent PE chains (one per output channel computed in parallel)
//   N_PES PEs per bank (input-channel parallelism within each chain)
//   All banks share the SAME activation input stream
//   Each bank has INDEPENDENT weights (different output channel)
//
//   Total PEs = N_BANKS × N_PES (default: 8 × 16 = 128)
//   Total DSP48E2 = N_BANKS × N_PES (one per PE for fraction multiply)
//
// Interface:
//   arr_weights: Flat packed array [N_BANKS*N_PES][16-bit]
//     Bank b, PE p weight = arr_weights[b*N_PES + p]
//   arr_act_in:  Single activation input (broadcast to all banks)
//   arr_results: N_BANKS simultaneous Posit16 outputs
// ============================================================================

module pdpu_array_banked #(
    parameter POSIT_WIDTH = `POSIT_WIDTH,
    parameter ES          = `ES,
    parameter ACC_WIDTH   = `ACC_WIDTH,
    parameter N_BANKS     = `N_BANKS,
    parameter N_PES       = `N_PES,
    parameter REGIME_MAX  = `REGIME_MAX
)(
    input  wire                                           clk,
    input  wire                                           rst,
    input  wire                                           en,
    input  wire                                           arr_load_weights,
    input  wire                                           arr_acc_clear,
    input  wire                                           arr_dot_done,
    input  wire [N_BANKS*N_PES-1:0][POSIT_WIDTH-1:0]    arr_weights,
    input  wire [POSIT_WIDTH-1:0]                         arr_act_in,
    output wire [N_BANKS-1:0][POSIT_WIDTH-1:0]           arr_results,
    output wire [N_BANKS-1:0]                             arr_results_valid
);

// ── Generate N_BANKS independent PE chains ────────────────────────────────
genvar b, p;
generate
    for (b = 0; b < N_BANKS; b = b + 1) begin : gen_bank

        // Activation chain for this bank (shared input, independent propagation)
        wire [POSIT_WIDTH-1:0] act_chain [0:N_PES];
        assign act_chain[0] = arr_act_in;  // Same activation for all banks

        // Per-PE accumulator outputs (flat wires, packed for reduction tree)
        wire [N_PES-1:0][ACC_WIDTH-1:0] acc_packed;

        // ── Generate N_PES Processing Elements per bank ───────────────────
        for (p = 0; p < N_PES; p = p + 1) begin : gen_pe
            wire [ACC_WIDTH-1:0] pe_acc_out_w;
            wire                 pe_acc_valid_w;

            pdpu_pe #(
                .POSIT_WIDTH (POSIT_WIDTH),
                .ES          (ES),
                .ACC_WIDTH   (ACC_WIDTH),
                .REGIME_MAX  (REGIME_MAX)
            ) u_pe (
                .clk            (clk),
                .rst            (rst),
                .en             (en),
                .pe_load_weight (arr_load_weights),
                .pe_acc_clear   (arr_acc_clear),
                .pe_weight_in   (arr_weights[b * N_PES + p]),
                .pe_act_in      (act_chain[p]),
                .pe_act_out     (act_chain[p + 1]),
                .pe_acc_out     (pe_acc_out_w),
                .pe_acc_valid   (pe_acc_valid_w)
            );

            assign acc_packed[p] = pe_acc_out_w;
        end

        // ── Reduction tree per bank ───────────────────────────────────────
        pdpu_reduction_tree #(
            .POSIT_WIDTH (POSIT_WIDTH),
            .ACC_WIDTH   (ACC_WIDTH),
            .N_PES       (N_PES)
        ) u_tree (
            .clk              (clk),
            .rst              (rst),
            .en               (en),
            .tree_start       (arr_dot_done),
            .tree_acc_in      (acc_packed),
            .tree_result      (arr_results[b]),
            .tree_result_valid(arr_results_valid[b])
        );

    end
endgenerate

endmodule
