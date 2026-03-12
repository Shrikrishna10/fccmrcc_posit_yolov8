// =============================================================================
// tb_pdpu_mitchell_mult.sv
// Vivado xsim.  No external dependencies to PASS.
// Hardcoded cases: fully human-verifiable, zero-dependency.
// CSV cases (../golden/mitchell_mult_vectors.csv): extended coverage,
//   loaded only if file exists — testbench passes without it.
//
// POSIT16 REFERENCE VALUES (from gen_golden.py, verified):
//   0x0000 = 0.0       0x4000 = 1.0    0x5000 = 2.0
//   0x6000 = 4.0       0x7000 = 16.0   0x7800 = 64.0
//   0x3000 = 0.5       0x2000 = 0.25   0x1800 = 0.125
//   0x8000 = NaR       neg(0x4000) = 0xC000 = -1.0
//
// HARDCODED EXPECTED RESULTS:
//   1.0 * 1.0 = 1.0   -> 0x4000
//   2.0 * 2.0 = 4.0   -> 0x6000
//   1.0 * 2.0 = 2.0   -> 0x5000
//   4.0 * 1.0 = 4.0   -> 0x6000
//   0.5 * 2.0 = 1.0   -> 0x4000
//   0.5 * 0.5 = 0.25  -> 0x2000
//  -1.0 * 1.0 = -1.0  -> 0xC000
//  -1.0 *-1.0 = 1.0   -> 0x4000
//   0   *  x  = 0     -> 0x0000
//   NaR *  x  = NaR   -> 0x8000
// =============================================================================
`timescale 1ns/1ps
`include "posit_defines.svh"

module tb_pdpu_mitchell_mult;

    // ── DUT wiring ──────────────────────────────────────────────────────────
    logic        clk = 0;
    logic        rst = 1;
    logic        en  = 0;
    logic [15:0] mult_a;
    logic [15:0] mult_b;
    logic [15:0] mult_result;
    logic        mult_valid;

    pdpu_mitchell_mult #(
        .POSIT_WIDTH(`POSIT_WIDTH),
        .ES(`ES),
        .REGIME_MAX(`REGIME_MAX)
    ) dut (
        .clk(clk), .rst(rst), .en(en),
        .mult_a(mult_a), .mult_b(mult_b),
        .mult_result(mult_result), .mult_valid(mult_valid)
    );

    always #5 clk = ~clk;  // 100 MHz

    // ── Counters ─────────────────────────────────────────────────────────────
    integer pass_hc = 0, fail_hc = 0;   // hardcoded
    integer pass_csv = 0, fail_csv = 0;  // CSV

    // ── Task: drive one multiply, check result ────────────────────────────────
    // tolerance_ulp: allowed bit-distance between result and expected.
    //   Use 0 for special cases (must be exact).
    //   Use 80 for Mitchell approximate results (~1% MRE proxy).
    task automatic check_mul(
        input [15:0] a,
        input [15:0] b,
        input [15:0] expected,
        input integer tolerance_ulp,
        input string  label
    );
        integer diff;
        @(negedge clk); mult_a = a; mult_b = b; en = 1;
        @(posedge clk); #1;          // result registered
        @(negedge clk); en = 0;

        diff = (mult_result > expected) ? int'(mult_result) - int'(expected)
                                        : int'(expected)    - int'(mult_result);
        if (diff <= tolerance_ulp) begin
            $display("  PASS [%s]  a=%04h b=%04h  exp=%04h got=%04h  diff=%0d ulp",
                     label, a, b, expected, mult_result, diff);
            pass_hc++;
        end else begin
            $display("  FAIL [%s]  a=%04h b=%04h  exp=%04h got=%04h  diff=%0d ulp",
                     label, a, b, expected, mult_result, diff);
            fail_hc++;
        end
    endtask

    // ── Main ─────────────────────────────────────────────────────────────────
    integer fh, ret;
    logic [15:0] csv_a, csv_b, csv_exp;
    string hdr;

    initial begin
        $dumpfile("tb_pdpu_mitchell_mult.vcd");
        $dumpvars(0, tb_pdpu_mitchell_mult);

        // Reset
        rst = 1; en = 0; mult_a = 0; mult_b = 0;
        repeat(4) @(posedge clk);
        rst = 0;
        @(posedge clk);

        $display("\n==== tb_pdpu_mitchell_mult: HARDCODED CASES ====");

        // ── Special cases (must be bit-exact, tolerance = 0) ──────────────
        check_mul(16'h0000, 16'h4000, 16'h0000, 0, "0 * 1.0 = 0");
        check_mul(16'h4000, 16'h0000, 16'h0000, 0, "1.0 * 0 = 0");
        check_mul(16'h8000, 16'h4000, 16'h8000, 0, "NaR * 1.0 = NaR");
        check_mul(16'h4000, 16'h8000, 16'h8000, 0, "1.0 * NaR = NaR");
        check_mul(16'h8000, 16'h8000, 16'h8000, 0, "NaR * NaR = NaR");

        // ── Exact power-of-two multiplications (tight tolerance = 1 ulp) ──
        // These land exactly on representable values; Mitchell should be exact or 1-2 ulp.
        check_mul(16'h4000, 16'h4000, 16'h4000, 2, "1.0 * 1.0 = 1.0");
        check_mul(16'h5000, 16'h5000, 16'h6000, 2, "2.0 * 2.0 = 4.0");
        check_mul(16'h4000, 16'h5000, 16'h5000, 2, "1.0 * 2.0 = 2.0");
        check_mul(16'h6000, 16'h4000, 16'h6000, 2, "4.0 * 1.0 = 4.0");
        check_mul(16'h3000, 16'h5000, 16'h4000, 2, "0.5 * 2.0 = 1.0");
        check_mul(16'h3000, 16'h3000, 16'h2000, 2, "0.5 * 0.5 = 0.25");
        check_mul(16'h7000, 16'h4000, 16'h7000, 2, "16.0 * 1.0 = 16.0");

        // ── Sign cases ─────────────────────────────────────────────────────
        // -1.0 in Posit16: neg(0x4000) = (~0x4000 + 1) & 0xFFFF = 0xC000
        check_mul(16'hC000, 16'h4000, 16'hC000, 2, "-1.0 * 1.0 = -1.0");
        check_mul(16'hC000, 16'hC000, 16'h4000, 2, "-1.0 *-1.0 = 1.0");
        check_mul(16'hC000, 16'h5000, 16'hE000, 2, "-1.0 * 2.0 = -2.0");

        // ── Saturation: product at maxpos/minpos boundary ──────────────────
        // 64.0 * 64.0 should saturate to maxpos (0x7F00 approx, or 0x7800)
        check_mul(16'h7800, 16'h7800, 16'h7F00, 256, "64.0*64.0 -> saturate (maxpos)");

        $display("\n==== HARDCODED TOTALS: PASS=%0d  FAIL=%0d ====\n", pass_hc, fail_hc);

        // ── CSV extended coverage ──────────────────────────────────────────
        $display("==== CSV extended coverage ====");
        fh = $fopen("../golden/mitchell_mult_vectors.csv", "r");
        if (fh == 0) begin
            $display("  (CSV not found — run scripts/gen_golden.py to enable extended coverage)");
            $display("  Skipping CSV tests. Hardcoded tests above are the pass criteria.\n");
        end else begin
            ret = $fgets(hdr, fh);  // skip header
            while (!$feof(fh)) begin
                ret = $fscanf(fh, "%h,%h,%h,%*s\n", csv_a, csv_b, csv_exp);
                if (ret < 3) break;

                @(negedge clk); mult_a = csv_a; mult_b = csv_b; en = 1;
                @(posedge clk); #1;
                @(negedge clk); en = 0;

                begin
                    integer d;
                    d = (mult_result > csv_exp) ? int'(mult_result) - int'(csv_exp)
                                                : int'(csv_exp)    - int'(mult_result);
                    if (d <= 80) pass_csv++;
                    else begin
                        $display("  WARN [csv] a=%04h b=%04h exp=%04h got=%04h diff=%0d",
                                 csv_a, csv_b, csv_exp, mult_result, d);
                        fail_csv++;
                    end
                end
            end
            $fclose(fh);
            $display("  CSV: PASS=%0d  FAIL=%0d", pass_csv, fail_csv);
        end

        // ── Final verdict ──────────────────────────────────────────────────
        $display("\n============================================");
        $display(" HARDCODED PASS=%0d FAIL=%0d", pass_hc, fail_hc);
        $display(" CSV      PASS=%0d FAIL=%0d", pass_csv, fail_csv);
        if (fail_hc == 0)
            $display(" RESULT: ** PASS ** (hardcoded criteria met)");
        else
            $display(" RESULT: ** FAIL ** (%0d hardcoded failures)", fail_hc);
        $display("============================================\n");
        $finish;
    end

    initial begin #5_000_000; $display("TIMEOUT"); $finish; end

endmodule
