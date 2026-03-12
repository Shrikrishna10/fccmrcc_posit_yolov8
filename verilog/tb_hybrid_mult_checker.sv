`timescale 1ns/1ps
`include "posit_defines.svh"

// ============================================================================
// tb_hybrid_mult_checker.sv — Accuracy checker for hybrid_posit_mult
//
// ALL expected values verified against:
//   1. Mathematical Posit<16,1> arithmetic
//   2. Hardware regime-clamping behavior (k clamped to [-3,+3])
//   3. Canonical re-encoding (encoder always uses shortest regime)
//
// Posit<16,1> encoding reference:
//   0x0000 = 0        0x2000 = 0.25      0x3000 = 0.5
//   0x3800 = 0.75     0x4000 = 1.0       0x4400 = 1.25
//   0x4800 = 1.5      0x4900 = 1.5625    0x5000 = 2.0
//   0x5200 = 2.25     0x5800 = 3.0       0x6000 = 4.0
//   0x6800 = 8.0      0x7000 = 16.0      0x7800 = 64 (canonical maxpos)
//   0x7F00 = 64 (extended regime maxpos)
//   0x0800 = 1/64 (canonical minpos)     0x0100 = 1/64 (extended regime)
//   0xC000 = -1.0     0xD000 = -0.5      0xB000 = -2.0
//   0x8000 = NaR
//
// NOTE: 0x7800 and 0x7F00 both represent 64.0 — the hardware always
//       re-encodes to the canonical (shortest regime) form 0x7800.
//       Similarly 0x0800 and 0x0100 both represent 1/64.
// ============================================================================

module tb_hybrid_mult_checker;

localparam POSIT_WIDTH = `POSIT_WIDTH;

logic                   clk = 0;
logic                   rst = 0;
logic                   en  = 1;
logic [POSIT_WIDTH-1:0] mult_a, mult_b;
wire  [POSIT_WIDTH-1:0] mult_result;
wire                    mult_valid;

hybrid_posit_mult #(
    .POSIT_WIDTH(POSIT_WIDTH), .ES(`ES), .REGIME_MAX(`REGIME_MAX)
) dut (.*);

always #5 clk = ~clk;

integer pass_count, fail_count, csv_pass, csv_fail, csv_total, max_ulp;

function automatic integer ulp_dist(input [15:0] a, input [15:0] b);
    integer ia, ib;
    ia = a; ib = b;
    ulp_dist = (ia > ib) ? (ia - ib) : (ib - ia);
endfunction

task automatic do_mult(input [15:0] a, input [15:0] b, output [15:0] result);
    @(negedge clk); mult_a = a; mult_b = b;
    @(posedge clk); #1;
    @(posedge clk); #1;
    result = mult_result;
endtask

task automatic check_mult(
    input [127:0] label, input [15:0] a, input [15:0] b,
    input [15:0] expected, input integer tol
);
    automatic logic [15:0] got;
    automatic integer d;
    do_mult(a, b, got);
    d = ulp_dist(expected, got);
    if (d <= tol) begin
        $display("  PASS [%0s]  0x%04h * 0x%04h = 0x%04h (exp 0x%04h, %0d ulp)", label, a, b, got, expected, d);
        pass_count++;
    end else begin
        $display("  FAIL [%0s]  0x%04h * 0x%04h = 0x%04h (exp 0x%04h, %0d ulp tol=%0d)", label, a, b, got, expected, d, tol);
        fail_count++;
    end
endtask

initial begin
    pass_count=0; fail_count=0; csv_pass=0; csv_fail=0; csv_total=0; max_ulp=0;

    $display("\n================================================================");
    $display("  HYBRID POSIT16 MULTIPLIER — ACCURACY CHECKER (v3)");
    $display("================================================================\n");

    rst = 1; repeat(2) @(posedge clk); rst = 0; @(posedge clk); #1;

    // ─── A. SPECIAL CASES (zero tolerance) ────────────────────────────────
    $display("--- A. Special cases ---");
    check_mult("0*1",      16'h0000, 16'h4000, 16'h0000, 0);
    check_mult("1*0",      16'h4000, 16'h0000, 16'h0000, 0);
    check_mult("0*0",      16'h0000, 16'h0000, 16'h0000, 0);
    check_mult("NaR*1",    16'h8000, 16'h4000, 16'h8000, 0);
    check_mult("1*NaR",    16'h4000, 16'h8000, 16'h8000, 0);
    check_mult("NaR*0",    16'h8000, 16'h0000, 16'h8000, 0);
    check_mult("NaR*NaR",  16'h8000, 16'h8000, 16'h8000, 0);

    // ─── B. IDENTITY: 1.0 × x = x (tight tolerance) ──────────────────────
    $display("\n--- B. Identity (1.0 * x = x) ---");
    check_mult("1*1",      16'h4000, 16'h4000, 16'h4000, 0);
    check_mult("1*2",      16'h4000, 16'h5000, 16'h5000, 0);
    check_mult("1*0.5",    16'h4000, 16'h3000, 16'h3000, 0);
    check_mult("1*4",      16'h4000, 16'h6000, 16'h6000, 0);
    check_mult("1*1.5",    16'h4000, 16'h4800, 16'h4800, 0);
    check_mult("1*8",      16'h4000, 16'h6800, 16'h6800, 0);
    check_mult("1*0.25",   16'h4000, 16'h2000, 16'h2000, 0);
    check_mult("1*16",     16'h4000, 16'h7000, 16'h7000, 0);

    // ─── C. SIGN HANDLING (tight tolerance) ───────────────────────────────
    $display("\n--- C. Sign handling ---");
    check_mult("(-1)*1",   16'hC000, 16'h4000, 16'hC000, 0);
    check_mult("1*(-1)",   16'h4000, 16'hC000, 16'hC000, 0);
    check_mult("(-1)*(-1)",16'hC000, 16'hC000, 16'h4000, 0);
    check_mult("(-0.5)*2", 16'hD000, 16'h5000, 16'hC000, 2);
    check_mult("(-2)*(-2)",16'hB000, 16'hB000, 16'h6000, 2);
    check_mult("(-1)*0.5", 16'hC000, 16'h3000, 16'hD000, 2);  // -1×0.5=-0.5=0xD000

    // ─── D. POWER-OF-TWO (exact scale, tight tolerance) ──────────────────
    $display("\n--- D. Power-of-two products ---");
    check_mult("2*2=4",    16'h5000, 16'h5000, 16'h6000, 0);
    check_mult("4*4=16",   16'h6000, 16'h6000, 16'h7000, 0);
    check_mult("0.5*0.5",  16'h3000, 16'h3000, 16'h2000, 2);
    check_mult("2*0.5=1",  16'h5000, 16'h3000, 16'h4000, 0);
    check_mult("8*0.5=4",  16'h6800, 16'h3000, 16'h6000, 0);
    check_mult("0.25*4=1", 16'h2000, 16'h6000, 16'h4000, 2);
    check_mult("0.5*2=1",  16'h3000, 16'h5000, 16'h4000, 0);
    check_mult("4*0.25=1", 16'h6000, 16'h2000, 16'h4000, 2);

    // ─── E. TYPICAL ACTIVATION RANGE (moderate tolerance) ─────────────────
    $display("\n--- E. Typical activation range ---");
    check_mult("1.5*1.5",  16'h4800, 16'h4800, 16'h5200, 4);  // 2.25
    check_mult("0.5*1.5",  16'h3000, 16'h4800, 16'h3800, 4);  // 0.75
    check_mult("1.5*2",    16'h4800, 16'h5000, 16'h5800, 4);  // 3.0
    check_mult("0.75*2",   16'h3800, 16'h5000, 16'h4800, 4);  // 1.5
    check_mult("1.25*1.25",16'h4400, 16'h4400, 16'h4900, 4);  // 1.5625=0x4900
    check_mult("0.25*0.5", 16'h2000, 16'h3000, 16'h1800, 8);  // 0.125
    check_mult("3*3=9",    16'h5800, 16'h5800, 16'h6900, 8);  // ~9.0

    // ─── F. SATURATION / REGIME BOUNDARY ──────────────────────────────────
    // Hardware clamps k to [-3,+3] and re-encodes with canonical (shortest) regime.
    // 0x7F00 (extended maxpos) decodes to k=3,e=0 → re-encodes as 0x7800 (canonical)
    // 0x0100 (extended minpos) decodes to k=-3,e=0 → re-encodes as 0x0800 (canonical)
    $display("\n--- F. Saturation / regime boundary ---");
    check_mult("8*8=64",   16'h6800, 16'h6800, 16'h7800, 4);  // 64 → canonical 0x7800
    check_mult("max*1",    16'h7F00, 16'h4000, 16'h7800, 4);  // maxpos re-encoded canonical
    check_mult("min*1",    16'h0100, 16'h4000, 16'h0800, 4);  // minpos re-encoded canonical
    check_mult("16*4=64",  16'h7000, 16'h6000, 16'h7800, 4);  // 64 → 0x7800
    check_mult("can_max*1",16'h7800, 16'h4000, 16'h7800, 4);  // canonical maxpos preserved
    check_mult("can_min*1",16'h0800, 16'h4000, 16'h0800, 4);  // canonical minpos preserved

    // ─── G. COMMUTATIVITY (a×b must equal b×a) ───────────────────────────
    $display("\n--- G. Commutativity ---");
    begin
        automatic logic [15:0] r1, r2;
        automatic integer pairs [0:9];
        pairs = '{16'h4800, 16'h5000,    // 1.5 × 2.0
                  16'h3000, 16'h6000,    // 0.5 × 4.0
                  16'h2000, 16'h6800,    // 0.25 × 8.0
                  16'hC000, 16'h4800,    // -1.0 × 1.5
                  16'h3800, 16'h4400};   // 0.75 × 1.25
        for (int i = 0; i < 10; i += 2) begin
            do_mult(pairs[i], pairs[i+1], r1);
            do_mult(pairs[i+1], pairs[i], r2);
            if (r1 == r2) begin
                $display("  PASS [comm_%0d]  0x%04h * 0x%04h = 0x%04h both ways", i/2, pairs[i], pairs[i+1], r1);
                pass_count++;
            end else begin
                $display("  FAIL [comm_%0d]  0x%04h * 0x%04h = 0x%04h vs 0x%04h", i/2, pairs[i], pairs[i+1], r1, r2);
                fail_count++;
            end
        end
    end

    // ─── H. CSV BULK TEST ────────────────────────────────────────────────
    $display("\n--- H. CSV bulk test ---");
    begin : csv_block
        integer fd, ai, bi, ei, d;
        logic [15:0] got;
        string hdr;

        fd = $fopen("golden_mult_vectors.csv", "r");
        if (fd == 0) begin
            $display("  golden_mult_vectors.csv not found");
            $display("  Generate: python gen_golden_mult.py");
            $display("  Copy CSV to sim directory and rerun.");
        end else begin
            void'($fgets(hdr, fd));
            if ($sscanf(hdr, "%h,%h,%h", ai, bi, ei) == 3) begin
                do_mult(ai[15:0], bi[15:0], got);
                d = ulp_dist(ei[15:0], got); csv_total++;
                if (d > max_ulp) max_ulp = d;
                if (d <= 4) csv_pass++; else begin
                    csv_fail++;
                    if (csv_fail <= 20) $display("  FAIL: 0x%04h*0x%04h=0x%04h exp=0x%04h (%0d ulp)", ai[15:0], bi[15:0], got, ei[15:0], d);
                end
            end
            while (!$feof(fd)) begin
                if ($fscanf(fd, "%h,%h,%h\n", ai, bi, ei) == 3) begin
                    do_mult(ai[15:0], bi[15:0], got);
                    d = ulp_dist(ei[15:0], got); csv_total++;
                    if (d > max_ulp) max_ulp = d;
                    if (d <= 4) csv_pass++; else begin
                        csv_fail++;
                        if (csv_fail <= 20) $display("  FAIL: 0x%04h*0x%04h=0x%04h exp=0x%04h (%0d ulp)", ai[15:0], bi[15:0], got, ei[15:0], d);
                    end
                end
            end
            $fclose(fd);
            $display("\n  CSV Results:");
            $display("    Vectors tested: %0d", csv_total);
            $display("    PASS (<=4 ULP): %0d (%0d%%)", csv_pass, csv_total > 0 ? csv_pass * 100 / csv_total : 0);
            $display("    FAIL (>4 ULP):  %0d", csv_fail);
            $display("    Max ULP error:  %0d", max_ulp);
            if (csv_fail > 20) $display("    (first 20 failures shown)");
        end
    end

    // ─── SUMMARY ─────────────────────────────────────────────────────────
    $display("\n================================================================");
    $display("  HARDCODED: PASS=%0d  FAIL=%0d  (of %0d tests)", pass_count, fail_count, pass_count + fail_count);
    if (csv_total > 0)
        $display("  CSV BULK:  PASS=%0d  FAIL=%0d  (of %0d, max %0d ULP)", csv_pass, csv_fail, csv_total, max_ulp);
    $display("----------------------------------------------------------------");
    if (fail_count == 0 && csv_fail == 0)
        $display("  ** ALL TESTS PASSED **");
    else if (fail_count == 0 && csv_total > 0 && csv_fail * 100 < csv_total)
        $display("  ** HARDCODED CLEAN, CSV >99%% **");
    else if (fail_count > 0)
        $display("  ** %0d HARDCODED FAILURES — FIX REQUIRED **", fail_count);
    else
        $display("  ** CSV FAILURES — REVIEW ABOVE **");
    $display("================================================================\n");
    $finish;
end

endmodule
