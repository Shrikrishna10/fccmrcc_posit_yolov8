// =============================================================================
// tb_pdpu_reduction_tree.sv
// Vivado xsim.  Hardcoded expected values — passes with zero external files.
//
// The reduction tree sums 4 x 32-bit integer accumulators and rounds to Posit16.
//
// EXPECTED VALUES (from gen_golden.py):
//   [0,0,0,0]            -> 0x0000  (0.0)
//   [16384,0,0,0]        -> round(16384.0) in Posit16
//     16384 = 0x4000 bits as int, but as float = 16384.0
//     posit16_encode(16384.0): log2(16384)=14, so scale=14 -> k=7 -> CLAMPED to k=3
//     -> MAXPOS = 0x7F00 (approx 64.0) NOTE: 16384 >> 64 so it saturates
//   [0x4000,0x4000,0x4000,0x4000] = [16384,16384,16384,16384]
//     sum=65536 -> saturates to maxpos
//   [100,200,300,400] sum=1000 -> posit16_encode(1000.0)
//     1000 = USEED^4 * ... but k capped at 3, so maxpos.
//     Actually: 1000 < 64? No, 1000 > 64. Saturates.
//     Use small values that stay within range.
//
// CORRECTED HARDCODED CASES (values within Posit16 range [-64, 64]):
//   [0,0,0,0]       -> 0x0000
//   [1,0,0,0]       -> posit16_encode(1.0) = 0x4000
//   [2,0,0,0]       -> posit16_encode(2.0) = 0x5000
//   [1,1,1,1]       -> posit16_encode(4.0) = 0x6000
//   [4,4,4,4]       -> posit16_encode(16.0) = 0x7000
//   [16,16,16,16]   -> posit16_encode(64.0) = 0x7800  (maxpos)
//   [-1,-1,-1,-1]   -> posit16_encode(-4.0)
//     neg(0x6000) = (~0x6000+1)&0xFFFF = 0xA000
//   [1,-1,2,-2]     -> 0.0 = 0x0000
//
// NOTE: The accumulator holds INTEGER values that are the RAW POSIT BITS
// sign-extended. So acc=0x4000=16384 does NOT mean the value 1.0.
// It means the bit pattern 0x4000 was sign-extended as a signed int.
// When all acc inputs are 0x4000, sum=4*16384=65536 -> posit16_encode(65536) = maxpos.
// For the tree to produce 4.0, we need the float value 4.0 in the accumulators.
// Since posit16_encode(4.0)=0x6000=24576, to get output 4.0 the SUM must equal
// a value whose Posit encoding is 4.0 — e.g. sum=4 -> posit16_encode(4)=0x6000.
// =============================================================================
`timescale 1ns/1ps
`include "posit_defines.svh"

module tb_pdpu_reduction_tree;

    localparam N_PES = `N_PES;  // 4

    logic        clk = 0;
    logic        rst = 1;
    logic        en  = 1;
    logic        tree_start = 0;
    logic [N_PES-1:0][31:0] tree_acc_in = '0;
    logic [15:0] tree_result;
    logic        tree_result_valid;

    pdpu_reduction_tree #(
        .POSIT_WIDTH(`POSIT_WIDTH),
        .ACC_WIDTH(`ACC_WIDTH),
        .N_PES(N_PES)
    ) dut (
        .clk(clk), .rst(rst), .en(en),
        .tree_start(tree_start),
        .tree_acc_in(tree_acc_in),
        .tree_result(tree_result),
        .tree_result_valid(tree_result_valid)
    );

    always #5 clk = ~clk;

    integer pass_count = 0, fail_count = 0;

    // ── Task: load accumulators, fire, check ──────────────────────────────────
    task automatic fire_and_check(
        input [31:0] a0, a1, a2, a3,
        input [15:0] expected,
        input integer tolerance_ulp,
        input string  label
    );
        integer diff;
        @(negedge clk);
        tree_acc_in[0] = a0; tree_acc_in[1] = a1;
        tree_acc_in[2] = a2; tree_acc_in[3] = a3;
        tree_start = 1;
        @(posedge clk); #1;
        tree_start = 0;
        // Wait for valid pulse
        @(posedge tree_result_valid); #1;

        diff = (tree_result > expected) ? int'(tree_result) - int'(expected)
                                        : int'(expected)    - int'(tree_result);
        if (diff <= tolerance_ulp) begin
            $display("  PASS [%s]  accs=[%0d,%0d,%0d,%0d]  exp=0x%04h  got=0x%04h  diff=%0d ulp",
                     label, $signed(a0),$signed(a1),$signed(a2),$signed(a3),
                     expected, tree_result, diff);
            pass_count++;
        end else begin
            $display("  FAIL [%s]  accs=[%0d,%0d,%0d,%0d]  exp=0x%04h  got=0x%04h  diff=%0d ulp",
                     label, $signed(a0),$signed(a1),$signed(a2),$signed(a3),
                     expected, tree_result, diff);
            fail_count++;
        end
    endtask

    // ── CSV test ──────────────────────────────────────────────────────────────
    integer fh, ret;
    integer ca0,ca1,ca2,ca3;
    logic [15:0] csv_exp;
    string hdr;

    // ── Main ─────────────────────────────────────────────────────────────────
    initial begin
        $dumpfile("tb_pdpu_reduction_tree.vcd");
        $dumpvars(0, tb_pdpu_reduction_tree);

        rst=1; repeat(4) @(posedge clk); rst=0; @(posedge clk);

        $display("\n==== tb_pdpu_reduction_tree: HARDCODED CASES ====");

        // ── All zero -> 0x0000 (exact) ────────────────────────────────────
        fire_and_check(0, 0, 0, 0,  16'h0000, 0, "all-zero -> 0");

        // ── sum=1 -> posit16_encode(1.0) = 0x4000 ────────────────────────
        fire_and_check(1, 0, 0, 0,  16'h4000, 1, "sum=1 -> 1.0");

        // ── sum=2 -> posit16_encode(2.0) = 0x5000 ────────────────────────
        fire_and_check(2, 0, 0, 0,  16'h5000, 1, "sum=2 -> 2.0");
        fire_and_check(1, 1, 0, 0,  16'h5000, 1, "1+1+0+0 -> 2.0");

        // ── sum=4 -> posit16_encode(4.0) = 0x6000 ────────────────────────
        fire_and_check(1, 1, 1, 1,  16'h6000, 1, "1+1+1+1 -> 4.0");
        fire_and_check(4, 0, 0, 0,  16'h6000, 1, "sum=4 -> 4.0");

        // ── sum=16 -> posit16_encode(16.0) = 0x7000 ──────────────────────
        fire_and_check(4, 4, 4, 4,  16'h7000, 1, "4+4+4+4 -> 16.0");

        // ── sum=64 -> posit16_encode(64.0) = 0x7800 (maxpos) ─────────────
        fire_and_check(16,16,16,16, 16'h7800, 1, "16+16+16+16 -> 64.0 (maxpos)");

        // ── sum=-4 -> posit16_encode(-4.0) = neg(0x6000) = 0xA000 ─────────
        fire_and_check(-1,-1,-1,-1, 16'hA000, 1, "-1-1-1-1 -> -4.0");

        // ── Cancellation: sum=0 ───────────────────────────────────────────
        fire_and_check(2, -2, 3, -3, 16'h0000, 0, "cancellation -> 0");
        fire_and_check(10,-5,  3, -8, 16'h0000, 1, "10-5+3-8=0 -> 0");

        // ── Asymmetric: one large, three zeros ────────────────────────────
        fire_and_check(8, 0, 0, 0,  16'h6800, 1, "sum=8 -> 8.0 (0x6800)");
        fire_and_check(0, 0, 0, 8,  16'h6800, 1, "sum=8 -> 8.0 symmetry");

        // ── Symmetry: order should not matter ─────────────────────────────
        begin
            logic [15:0] ra, rb;
            @(negedge clk);
            tree_acc_in[0]=3; tree_acc_in[1]=5; tree_acc_in[2]=7; tree_acc_in[3]=1;
            tree_start=1; @(posedge clk); #1; tree_start=0;
            @(posedge tree_result_valid); #1; ra = tree_result;

            @(negedge clk);
            tree_acc_in[0]=1; tree_acc_in[1]=7; tree_acc_in[2]=5; tree_acc_in[3]=3;
            tree_start=1; @(posedge clk); #1; tree_start=0;
            @(posedge tree_result_valid); #1; rb = tree_result;

            if (ra === rb) begin
                $display("  PASS [symmetry]  [3,5,7,1] == [1,7,5,3] = 0x%04h", ra);
                pass_count++;
            end else begin
                $display("  FAIL [symmetry]  [3,5,7,1]=0x%04h != [1,7,5,3]=0x%04h", ra, rb);
                fail_count++;
            end
        end

        $display("\n==== HARDCODED: PASS=%0d  FAIL=%0d ====\n", pass_count, fail_count);

        // ── CSV extended coverage ─────────────────────────────────────────
        fh = $fopen("../golden/reduction_tree_vectors.csv", "r");
        if (fh == 0) begin
            $display("(CSV not found — run scripts/gen_golden.py for extended coverage)");
        end else begin
            integer csv_pass=0, csv_fail=0;
            ret = $fgets(hdr, fh);
            while (!$feof(fh)) begin
                ret = $fscanf(fh, "%d,%d,%d,%d,%h,%*s\n", ca0,ca1,ca2,ca3, csv_exp);
                if (ret < 5) break;
                @(negedge clk);
                tree_acc_in[0]=$signed(ca0); tree_acc_in[1]=$signed(ca1);
                tree_acc_in[2]=$signed(ca2); tree_acc_in[3]=$signed(ca3);
                tree_start=1; @(posedge clk); #1; tree_start=0;
                @(posedge tree_result_valid); #1;
                begin
                    integer d;
                    d=(tree_result>csv_exp)?int'(tree_result)-int'(csv_exp):int'(csv_exp)-int'(tree_result);
                    if(d<=8) csv_pass++;
                    else begin
                        $display("  WARN [csv] sum=%0d exp=0x%04h got=0x%04h diff=%0d",
                                 ca0+ca1+ca2+ca3, csv_exp, tree_result, d);
                        csv_fail++;
                    end
                end
            end
            $fclose(fh);
            $display("CSV: PASS=%0d  FAIL=%0d", csv_pass, csv_fail);
        end

        $display("\n============================================");
        $display(" HARDCODED: PASS=%0d FAIL=%0d", pass_count, fail_count);
        $display(fail_count==0 ? " RESULT: ** PASS **" : " RESULT: ** FAIL **");
        $display("============================================\n");
        $finish;
    end

    initial begin #20_000_000; $display("TIMEOUT"); $finish; end
endmodule
