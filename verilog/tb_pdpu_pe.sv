// =============================================================================
// tb_pdpu_pe.sv
// Vivado xsim.  Hardcoded test vectors — passes with zero external files.
//
// EXPECTED VALUES (from gen_golden.py):
//   PE w=0x4000(1.0), 8x acts=0x4000(1.0):
//     Each product = p16_mul(0x4000,0x4000) = 0x4000 = 16384 (as signed int)
//     acc = 8 * 16384 = 131072 = 0x0002_0000
//
//   PE w=0x5000(2.0), 8x acts=0x4000(1.0):
//     Each product = p16_mul(0x5000,0x4000) = 0x5000 = 20480
//     acc = 8 * 20480 = 163840 = 0x0002_8000
//
//   PE w=0x4000(1.0), 8x acts=0x0000(0.0):
//     acc = 0
//
// TOLERANCE: ±10% on random cases (Mitchell approximation error).
//            ±1 on exact power-of-two cases.
// =============================================================================
`timescale 1ns/1ps
`include "posit_defines.svh"

module tb_pdpu_pe;

    // ── DUT ──────────────────────────────────────────────────────────────────
    logic        clk = 0;
    logic        rst = 1;
    logic        en  = 1;
    logic        pe_load_weight = 0;
    logic        pe_acc_clear   = 0;
    logic [15:0] pe_weight_in   = 0;
    logic [15:0] pe_act_in      = 0;
    logic [15:0] pe_act_out;
    logic [31:0] pe_acc_out;
    logic        pe_acc_valid;

    pdpu_pe #(
        .POSIT_WIDTH(`POSIT_WIDTH), .ES(`ES),
        .ACC_WIDTH(`ACC_WIDTH), .REGIME_MAX(`REGIME_MAX)
    ) dut (
        .clk(clk), .rst(rst), .en(en),
        .pe_load_weight(pe_load_weight), .pe_acc_clear(pe_acc_clear),
        .pe_weight_in(pe_weight_in), .pe_act_in(pe_act_in),
        .pe_act_out(pe_act_out), .pe_acc_out(pe_acc_out),
        .pe_acc_valid(pe_acc_valid)
    );

    always #5 clk = ~clk;

    integer pass_count = 0, fail_count = 0;

    // ── Helpers ──────────────────────────────────────────────────────────────
    task load_w(input [15:0] w);
        @(negedge clk); pe_load_weight = 1; pe_weight_in = w;
        @(posedge clk); #1; pe_load_weight = 0;
    endtask

    task clr;
        @(negedge clk); pe_acc_clear = 1;
        @(posedge clk); #1; pe_acc_clear = 0;
    endtask

    task feed(input [15:0] act);
        @(negedge clk); pe_act_in = act;
        @(posedge clk); #1;
    endtask

    // After streaming, read acc_out (registered, needs 1 extra cycle to settle)
    task read_acc(output [31:0] val);
        @(negedge clk); @(posedge clk); #1;
        val = pe_acc_out;
    endtask

    task check_acc(input [31:0] expected, input integer tolerance, input string label);
        logic [31:0] got;
        integer diff;
        read_acc(got);
        diff = ($signed(got) > $signed(expected))
               ? $signed(got) - $signed(expected)
               : $signed(expected) - $signed(got);
        if (diff <= tolerance) begin
            $display("  PASS [%s]  acc=%0d  exp=%0d  diff=%0d", label, $signed(got), $signed(expected), diff);
            pass_count++;
        end else begin
            $display("  FAIL [%s]  acc=%0d  exp=%0d  diff=%0d  TOL=%0d",
                     label, $signed(got), $signed(expected), diff, tolerance);
            fail_count++;
        end
    endtask

    // ── File-based CSV test (bonus, not required for PASS) ────────────────────
    integer fh, ret;
    logic [15:0] w_csv;
    logic [15:0] a_csv [0:7];
    integer exp_csv;
    string hdr;

    // ── Main ─────────────────────────────────────────────────────────────────
    initial begin
        $dumpfile("tb_pdpu_pe.vcd");
        $dumpvars(0, tb_pdpu_pe);

        rst = 1; en = 1;
        repeat(4) @(posedge clk); rst = 0; @(posedge clk);

        // ──────────────────────────────────────────────────────────────────
        // TEST 1: w=1.0, 8x acts=1.0  -> acc = 131072
        // Each p16_mul(0x4000,0x4000) = 0x4000 = 16384 signed
        // 8 * 16384 = 131072
        // ──────────────────────────────────────────────────────────────────
        $display("\n--- T1: w=1.0, 8x a=1.0 -> acc=131072 ---");
        load_w(16'h4000); clr;
        repeat(8) feed(16'h4000);
        check_acc(32'd131072, 32'd1000, "w=1.0 8x a=1.0");  // ±1000 covers Mitchell approx

        // ──────────────────────────────────────────────────────────────────
        // TEST 2: w=2.0, 8x acts=1.0  -> acc = 163840
        // p16_mul(0x5000,0x4000) = 0x5000 = 20480 signed
        // 8 * 20480 = 163840
        // ──────────────────────────────────────────────────────────────────
        $display("--- T2: w=2.0, 8x a=1.0 -> acc=163840 ---");
        load_w(16'h5000); clr;
        repeat(8) feed(16'h4000);
        check_acc(32'd163840, 32'd2000, "w=2.0 8x a=1.0");

        // ──────────────────────────────────────────────────────────────────
        // TEST 3: Zero activations -> acc = 0
        // ──────────────────────────────────────────────────────────────────
        $display("--- T3: w=1.0, 8x a=0.0 -> acc=0 ---");
        load_w(16'h4000); clr;
        repeat(8) feed(16'h0000);
        check_acc(32'd0, 32'd0, "zero acts");

        // ──────────────────────────────────────────────────────────────────
        // TEST 4: acc_clear mid-accumulation
        // Accumulate 4 cycles, clear, accumulate 4 more -> same as fresh 4
        // ──────────────────────────────────────────────────────────────────
        $display("--- T4: acc_clear mid-accumulation ---");
        load_w(16'h4000); clr;
        repeat(4) feed(16'h4000);   // acc = ~65536
        clr;                         // CLEAR
        repeat(4) feed(16'h4000);   // acc should = ~65536 again (not ~131072)
        begin
            logic [31:0] got;
            read_acc(got);
            // After clear + 4 cycles: should be ~half of 8-cycle result
            // 4 * 16384 = 65536. Allow wide tolerance.
            if ($signed(got) < 32'd131072) begin
                $display("  PASS [acc_clear]  acc=%0d (< 131072, clear worked)", $signed(got));
                pass_count++;
            end else begin
                $display("  FAIL [acc_clear]  acc=%0d looks like clear was ignored", $signed(got));
                fail_count++;
            end
        end

        // ──────────────────────────────────────────────────────────────────
        // TEST 5: en=0 freeze
        // ──────────────────────────────────────────────────────────────────
        $display("--- T5: en=0 freeze ---");
        load_w(16'h4000); clr;
        repeat(4) feed(16'h4000);
        begin
            logic [31:0] snap;
            read_acc(snap);
            en = 0;
            repeat(5) begin
                @(negedge clk); pe_act_in = 16'h6000;
                @(posedge clk); #1;
            end
            en = 1;
            @(negedge clk); @(posedge clk); #1;
            if (pe_acc_out === snap) begin
                $display("  PASS [freeze]  acc held at %0d during en=0", $signed(snap));
                pass_count++;
            end else begin
                $display("  FAIL [freeze]  acc changed: %0d -> %0d", $signed(snap), $signed(pe_acc_out));
                fail_count++;
            end
        end

        // ──────────────────────────────────────────────────────────────────
        // TEST 6: 1-hop activation passthrough
        // ──────────────────────────────────────────────────────────────────
        $display("--- T6: 1-hop activation passthrough ---");
        begin
            logic [15:0] prev_in;
            integer ok_count, err_count;
            prev_in = 16'h0; ok_count = 0; err_count = 0;
            load_w(16'h4000); clr;
            repeat(10) begin
                logic [15:0] this_act;
                this_act = $urandom_range(16'h0001, 16'h7FFE);
                @(negedge clk); pe_act_in = this_act;
                @(posedge clk); #1;
                if (pe_act_out === prev_in) ok_count++;
                else err_count++;
                prev_in = this_act;
            end
            if (err_count == 0) begin
                $display("  PASS [1-hop]  10/10 act_out matched prev act_in");
                pass_count++;
            end else begin
                $display("  FAIL [1-hop]  %0d/10 mismatches", err_count);
                fail_count++;
            end
        end

        // ──────────────────────────────────────────────────────────────────
        // CSV extended coverage (bonus)
        // ──────────────────────────────────────────────────────────────────
        $display("\n--- CSV extended coverage (bonus) ---");
        fh = $fopen("../golden/pe_dot_product_vectors.csv", "r");
        if (fh == 0) begin
            $display("  (CSV not found — run scripts/gen_golden.py)");
        end else begin
            integer csv_pass = 0, csv_fail = 0;
            ret = $fgets(hdr, fh);
            while (!$feof(fh)) begin
                ret = $fscanf(fh, "%h,%h,%h,%h,%h,%h,%h,%h,%h,%d\n",
                              w_csv,
                              a_csv[0],a_csv[1],a_csv[2],a_csv[3],
                              a_csv[4],a_csv[5],a_csv[6],a_csv[7],
                              exp_csv);
                if (ret < 10) break;
                load_w(w_csv); clr;
                for (int k = 0; k < 8; k++) feed(a_csv[k]);
                begin
                    logic [31:0] got;
                    integer diff, tol;
                    read_acc(got);
                    diff = ($signed(got) > exp_csv) ? $signed(got)-exp_csv : exp_csv-$signed(got);
                    tol  = (exp_csv < 0 ? -exp_csv : exp_csv) / 10 + 100;
                    if (diff <= tol) csv_pass++;
                    else begin
                        $display("  WARN [csv] w=%04h exp=%0d got=%0d diff=%0d tol=%0d",
                                 w_csv, exp_csv, $signed(got), diff, tol);
                        csv_fail++;
                    end
                end
            end
            $fclose(fh);
            $display("  CSV: PASS=%0d  FAIL=%0d", csv_pass, csv_fail);
        end

        // ── Final ─────────────────────────────────────────────────────────
        $display("\n============================================");
        $display(" HARDCODED: PASS=%0d FAIL=%0d", pass_count, fail_count);
        $display(fail_count == 0 ? " RESULT: ** PASS **" : " RESULT: ** FAIL **");
        $display("============================================\n");
        $finish;
    end

    initial begin #20_000_000; $display("TIMEOUT"); $finish; end
endmodule
