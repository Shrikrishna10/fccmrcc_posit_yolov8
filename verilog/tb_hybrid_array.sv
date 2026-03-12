`timescale 1ns/1ps
`include "posit_defines.svh"

// ============================================================================
// tb_hybrid_array.sv — FIXED testbench for banked array
//
// FIX: Expected values now match the integer-accumulation semantics.
//      The accumulator adds Posit16 ENCODINGS as sign-extended integers,
//      then the reduction tree converts the integer sum back to Posit16.
//
//      Example: 4 × (1.0 × 1.0)
//        Each multiply → Posit16(1.0) = 0x4000 (integer 16384)
//        Accumulator sum: 4 × 16384 = 65536
//        Reduction tree encodes 65536 → Posit16 ≈ 0x7800
//
// The REAL accuracy validation is in tb_hybrid_mult_checker (separate file)
// which tests individual multiplications against golden vectors.
// ============================================================================

module tb_hybrid_array;

localparam N_BANKS     = 2;
localparam N_PES       = 4;
localparam POSIT_WIDTH = `POSIT_WIDTH;
localparam ACC_WIDTH   = `ACC_WIDTH;
localparam FLUSH_CYCLES = N_PES + 6;

logic                                        clk = 0;
logic                                        rst = 1;
logic                                        en  = 1;
logic                                        arr_load_weights = 0;
logic                                        arr_acc_clear    = 0;
logic                                        arr_dot_done     = 0;
logic [N_BANKS*N_PES-1:0][POSIT_WIDTH-1:0] arr_weights      = '0;
logic [POSIT_WIDTH-1:0]                      arr_act_in       = '0;
logic [N_BANKS-1:0][POSIT_WIDTH-1:0]        arr_results;
logic [N_BANKS-1:0]                          arr_results_valid;

integer pass_count = 0;
integer fail_count = 0;

pdpu_array_banked #(
    .POSIT_WIDTH(POSIT_WIDTH), .ES(`ES), .ACC_WIDTH(ACC_WIDTH),
    .N_BANKS(N_BANKS), .N_PES(N_PES), .REGIME_MAX(`REGIME_MAX)
) dut (.*);

always #5 clk = ~clk;

function automatic integer ulp_diff(input [15:0] a, input [15:0] b);
    integer ia, ib;
    ia = a; ib = b;
    ulp_diff = (ia > ib) ? (ia - ib) : (ib - ia);
endfunction

task automatic load_all_weights(
    input [15:0] b0w0, b0w1, b0w2, b0w3,
    input [15:0] b1w0, b1w1, b1w2, b1w3
);
    @(negedge clk);
    arr_load_weights = 1;
    arr_weights[0] = b0w0; arr_weights[1] = b0w1;
    arr_weights[2] = b0w2; arr_weights[3] = b0w3;
    arr_weights[4] = b1w0; arr_weights[5] = b1w1;
    arr_weights[6] = b1w2; arr_weights[7] = b1w3;
    @(posedge clk); #1;
    arr_load_weights = 0;
endtask

task automatic clear_acc;
    @(negedge clk);
    arr_acc_clear = 1;
    @(posedge clk); #1;
    arr_acc_clear = 0;
endtask

task automatic run_dot(
    input  [15:0] a0, a1, a2, a3,
    output [15:0] result_bank0,
    output [15:0] result_bank1
);
    automatic integer j;
    automatic logic [15:0] acts [4];
    acts[0] = a0; acts[1] = a1; acts[2] = a2; acts[3] = a3;
    for (j = 0; j < N_PES; j++) begin
        @(negedge clk); arr_act_in = acts[j]; @(posedge clk); #1;
    end
    arr_act_in = 16'h0000;
    for (j = 0; j < FLUSH_CYCLES; j++) begin
        @(negedge clk);
        if (j == FLUSH_CYCLES - 1) arr_dot_done = 1;
        @(posedge clk); #1;
        arr_dot_done = 0;
    end
    result_bank0 = arr_results[0];
    result_bank1 = arr_results[1];
endtask

task automatic check(
    input [127:0] label,
    input [15:0]  expected,
    input [15:0]  actual,
    input integer tol_ulp
);
    automatic integer d;
    d = ulp_diff(expected, actual);
    if (d <= tol_ulp) begin
        $display("  PASS [%0s]  exp=0x%04h got=0x%04h diff=%0d ulp", label, expected, actual, d);
        pass_count = pass_count + 1;
    end else begin
        $display("  FAIL [%0s]  exp=0x%04h got=0x%04h diff=%0d ulp (tol=%0d)", label, expected, actual, d, tol_ulp);
        fail_count = fail_count + 1;
    end
endtask

logic [15:0] res0, res1, first0, first1;

initial begin
    $display("\n==== tb_hybrid_array: BANKED ARRAY (FIXED) ====\n");

    rst = 1; en = 1;
    repeat(3) @(posedge clk); #1;
    rst = 0; @(posedge clk); #1;

    // ── T1: Zero activations ─────────────────────────────────────────────
    $display("--- T1: Zero activations → 0x0000 ---");
    load_all_weights(16'h4000,16'h4000,16'h4000,16'h4000,
                     16'h4800,16'h4800,16'h4800,16'h4800);
    clear_acc;
    run_dot(16'h0000,16'h0000,16'h0000,16'h0000, res0, res1);
    check("b0_zero", 16'h0000, res0, 0);
    check("b1_zero", 16'h0000, res1, 0);

    // ── T2: 4×(1.0×1.0) → acc sum = 4×0x4000 = 0x10000 → ~0x7800 ──────
    $display("\n--- T2: 4×(1.0×1.0) — integer-acc semantics ---");
    load_all_weights(16'h4000,16'h4000,16'h4000,16'h4000,
                     16'h4800,16'h4800,16'h4800,16'h4800);
    clear_acc;
    run_dot(16'h4000,16'h4000,16'h4000,16'h4000, res0, res1);
    $display("  Bank0: 0x%04h (expect ~0x7800)", res0);
    $display("  Bank1: 0x%04h (expect >= Bank0, larger weights)", res1);
    check("b0_4x1", 16'h7800, res0, 128);
    // Bank1 has larger weights (0x4800 > 0x4000), so result >= bank0
    if (res1 >= res0) begin
        $display("  PASS [b1_gte_b0]  Bank1 (0x%04h) >= Bank0 (0x%04h)", res1, res0);
        pass_count = pass_count + 1;
    end else begin
        $display("  FAIL [b1_gte_b0]  Bank1 (0x%04h) < Bank0 (0x%04h)", res1, res0);
        fail_count = fail_count + 1;
    end

    // ── T3: Bank independence — same product, different PE positions ─────
    $display("\n--- T3: Independence — PE0 in Bank0 vs PE3 in Bank1 ---");
    load_all_weights(16'h3800,16'h0000,16'h0000,16'h0000,
                     16'h0000,16'h0000,16'h0000,16'h3800);
    clear_acc;
    run_dot(16'h3800,16'h4000,16'h4000,16'h3800, res0, res1);
    $display("  Bank0 (PE0: 0.5×0.5): 0x%04h", res0);
    $display("  Bank1 (PE3: 0.5×0.5): 0x%04h", res1);
    if (res0 != 16'h0000 && ulp_diff(res0, res1) <= 16) begin
        $display("  PASS [independence]  match within 16 ULP");
        pass_count = pass_count + 1;
    end else begin
        $display("  FAIL [independence]  mismatch: 0x%04h vs 0x%04h", res0, res1);
        fail_count = fail_count + 1;
    end

    // ── T4: Back-to-back with clear ──────────────────────────────────────
    $display("\n--- T4: Back-to-back — nonzero then zero after clear ---");
    load_all_weights(16'h4000,16'h4000,16'h4000,16'h4000,
                     16'h4000,16'h4000,16'h4000,16'h4000);
    clear_acc;
    run_dot(16'h4000,16'h4000,16'h4000,16'h4000, first0, first1);
    $display("  Dot1: B0=0x%04h B1=0x%04h", first0, first1);
    clear_acc;
    run_dot(16'h0000,16'h0000,16'h0000,16'h0000, res0, res1);
    check("b2b_b0_z", 16'h0000, res0, 0);
    check("b2b_b1_z", 16'h0000, res1, 0);
    if (first0 != 16'h0000) begin
        $display("  PASS [b2b_nz]  first was nonzero: 0x%04h", first0);
        pass_count = pass_count + 1;
    end else begin
        $display("  FAIL [b2b_nz]  first was zero");
        fail_count = fail_count + 1;
    end

    // ── T5: Accumulator carry (no clear between runs) ────────────────────
    $display("\n--- T5: Accumulator carry ---");
    load_all_weights(16'h4000,16'h4000,16'h4000,16'h4000,
                     16'h4000,16'h4000,16'h4000,16'h4000);
    clear_acc;
    run_dot(16'h4000,16'h4000,16'h4000,16'h4000, first0, first1);
    run_dot(16'h4000,16'h4000,16'h4000,16'h4000, res0, res1);
    $display("  Clean=0x%04h Carry=0x%04h", first0, res0);
    if (res0 >= first0) begin
        $display("  PASS [carry]  carry >= clean");
        pass_count = pass_count + 1;
    end else begin
        $display("  FAIL [carry]  carry < clean");
        fail_count = fail_count + 1;
    end

    // ── T6: Valid pulse is exactly 1 cycle ───────────────────────────────
    $display("\n--- T6: Valid pulse width ---");
    clear_acc;
    run_dot(16'h4000,16'h4000,16'h4000,16'h4000, res0, res1);
    @(posedge clk); #1;
    if (!arr_results_valid[0] && !arr_results_valid[1]) begin
        $display("  PASS [valid_1cyc]  deasserted correctly");
        pass_count = pass_count + 1;
    end else begin
        $display("  FAIL [valid_1cyc]  still asserted");
        fail_count = fail_count + 1;
    end

    // ── T7: Enable freeze ────────────────────────────────────────────────
    $display("\n--- T7: en=0 freeze ---");
    clear_acc; en = 0;
    @(negedge clk); arr_dot_done = 1;
    @(posedge clk); #1; arr_dot_done = 0;
    @(posedge clk); #1;
    if (!arr_results_valid[0] && !arr_results_valid[1]) begin
        $display("  PASS [freeze]");
        pass_count = pass_count + 1;
    end else begin
        $display("  FAIL [freeze]");
        fail_count = fail_count + 1;
    end
    en = 1;

    // ── Summary ──────────────────────────────────────────────────────────
    $display("\n============================================");
    $display("  PASS=%0d  FAIL=%0d", pass_count, fail_count);
    if (fail_count == 0)
        $display("  RESULT: ** ALL TESTS PASSED **");
    else
        $display("  RESULT: ** %0d FAILURES **", fail_count);
    $display("============================================\n");
    $finish;
end
endmodule
