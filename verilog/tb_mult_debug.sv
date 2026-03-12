`timescale 1ns/1ps
`include "posit_defines.svh"

// ============================================================================
// tb_mult_debug.sv — Diagnostic probe for hybrid_posit_mult internal signals
//
// Tests the failing case: 0x4000 × 0x3000 (1.0 × 0.5 = 0.5)
// and prints every intermediate decode/scale/fraction/encode value
// so you can see exactly where the computation goes wrong.
// ============================================================================

module tb_mult_debug;

localparam PW = `POSIT_WIDTH;

logic        clk = 0;
logic        rst = 0;
logic        en  = 1;
logic [15:0] a_in, b_in;
wire  [15:0] result;
wire         valid;

hybrid_posit_mult #(
    .POSIT_WIDTH(PW), .ES(`ES), .REGIME_MAX(`REGIME_MAX)
) dut (
    .clk(clk), .rst(rst), .en(en),
    .mult_a(a_in), .mult_b(b_in),
    .mult_result(result), .mult_valid(valid)
);

always #5 clk = ~clk;

task automatic probe(input [15:0] a, input [15:0] b, input [127:0] label);
    @(negedge clk);
    a_in = a; b_in = b;
    @(posedge clk); #1;

    $display("\n=== %0s: 0x%04h × 0x%04h ===", label, a, b);

    // Access internal signals via hierarchical references
    $display("  Decode A:");
    $display("    body_a   = 0x%04h = %015b", dut.body_a, dut.body_a);
    $display("    rbit_a   = %0b", dut.rbit_a);
    $display("    run_a    = %0d", dut.run_a);
    $display("    k_a_s    = %0d (signed)", $signed(dut.k_a_s));
    $display("    k_a      = %0d (clamped)", $signed(dut.k_a));
    $display("    cons_a   = %0d", dut.cons_a);
    $display("    exp_a    = %0b", dut.exp_a);
    $display("    fshift_a = 0x%04h = %015b", dut.fshift_a, dut.fshift_a);
    $display("    frac_a   = 0x%03h = %011b (%0d)", dut.frac_a, dut.frac_a, dut.frac_a);

    $display("  Decode B:");
    $display("    body_b   = 0x%04h = %015b", dut.body_b, dut.body_b);
    $display("    rbit_b   = %0b", dut.rbit_b);
    $display("    run_b    = %0d", dut.run_b);
    $display("    k_b_s    = %0d (signed)", $signed(dut.k_b_s));
    $display("    k_b      = %0d (clamped)", $signed(dut.k_b));
    $display("    cons_b   = %0d", dut.cons_b);
    $display("    exp_b    = %0b", dut.exp_b);
    $display("    fshift_b = 0x%04h = %015b", dut.fshift_b, dut.fshift_b);
    $display("    frac_b   = 0x%03h = %011b (%0d)", dut.frac_b, dut.frac_b, dut.frac_b);

    $display("  Scale:");
    $display("    scale_a      = %0d", $signed(dut.scale_a));
    $display("    scale_b      = %0d", $signed(dut.scale_b));
    $display("    scale_r_wide = %0d", $signed(dut.scale_r_wide));

    $display("  Fraction multiply:");
    $display("    sig_a        = 0x%03h = %012b (%0d)", dut.sig_a, dut.sig_a, dut.sig_a);
    $display("    sig_b        = 0x%03h = %012b (%0d)", dut.sig_b, dut.sig_b, dut.sig_b);
    $display("    sig_product  = 0x%06h = %024b (%0d)", dut.sig_product, dut.sig_product, dut.sig_product);
    $display("    frac_overflow= %0b", dut.frac_overflow);
    $display("    frac_r       = 0x%03h = %011b", dut.frac_r, dut.frac_r);

    $display("  Adjusted scale:");
    $display("    scale_adjusted = %0d", $signed(dut.scale_adjusted));
    $display("    scale_r        = %0d", $signed(dut.scale_r));
    $display("    k_r_s          = %0d", $signed(dut.k_r_s));
    $display("    exp_r          = %0b", dut.exp_r);
    $display("    k_r            = %0d", $signed(dut.k_r));

    $display("  Encode:");
    $display("    k_neg_r  = %0b", dut.k_neg_r);
    $display("    k_mag_r  = %0d", dut.k_mag_r);
    $display("    body_r   = 0x%04h = %015b", dut.body_r, dut.body_r);
    $display("    result_sign    = %0b", dut.result_sign);
    $display("    encoded_pos    = 0x%04h", dut.encoded_pos);
    $display("    result_normal  = 0x%04h", dut.result_normal);
    $display("    special        = %0b", dut.special);
    $display("    scale_overflow = %0b", dut.scale_overflow);
    $display("    mult_result_next = 0x%04h", dut.mult_result_next);

    // Wait for registered output
    @(posedge clk); #1;
    $display("  FINAL: mult_result = 0x%04h  mult_valid = %0b", result, valid);
endtask

initial begin
    $display("\n================================================================");
    $display("  HYBRID MULT — INTERNAL SIGNAL DIAGNOSTIC");
    $display("================================================================");

    rst = 1; repeat(2) @(posedge clk); rst = 0; @(posedge clk); #1;

    // Known-good case: 1.0 × 1.0 = 1.0
    probe(16'h4000, 16'h4000, "1.0 x 1.0 = 1.0");

    // FAILING case: 1.0 × 0.5 = 0.5 (got 0x5000 = 2.0)
    probe(16'h4000, 16'h3000, "1.0 x 0.5 = 0.5 FAIL");

    // FAILING case: 0.5 × 0.5 = 0.25 (got 0x4000 = 1.0)
    probe(16'h3000, 16'h3000, "0.5 x 0.5 = 0.25 FAIL");

    // FAILING case: maxpos × 1.0 (got 0x7800)
    probe(16'h7F00, 16'h4000, "maxpos x 1.0 FAIL");

    // FAILING case: minpos × 1.0 (got 0x0800)
    probe(16'h0100, 16'h4000, "minpos x 1.0 FAIL");

    // Known-good: 2.0 × 2.0 = 4.0
    probe(16'h5000, 16'h5000, "2.0 x 2.0 = 4.0");

    // Known-good: 1.5 × 1.5 = 2.25
    probe(16'h4800, 16'h4800, "1.5 x 1.5 = 2.25");

    $display("\n================================================================");
    $display("  Examine the FAILING cases above.");
    $display("  Compare decode values (k, exp, frac) against expected:");
    $display("    0x3000 (0.5): k=-1, exp=1, frac=0");
    $display("    0x7F00 (64) : k=3,  exp=0, frac=~0x700");
    $display("    0x0100 (1/64): k=-3, exp=0, frac=0");
    $display("================================================================\n");

    $finish;
end

endmodule
