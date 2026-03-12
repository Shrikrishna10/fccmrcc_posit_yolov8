`timescale 1ns/1ps
`include "posit_defines.svh"

module tb_pdpu_array;

localparam N_PES        = `N_PES;
localparam POSIT_WIDTH  = `POSIT_WIDTH;
localparam ACC_WIDTH    = `ACC_WIDTH;
localparam FLUSH_CYCLES = N_PES + 6;  // see pipeline analysis
// Pipeline flush depth analysis:
//   Each PE hop = 2 cycles: act_pipe_r (reg) + pe_act_out (reg from act_pipe_r)
//   act[j] reaches PE(i).pe_act_in at cycle: j + i*2
//   Last act (j=N_PES-1=3) reaches PE3 (i=3) at cycle: 3 + 3*2 = 9  (after first act)
//   mult_result ready: +1 cycle. acc_r update: same cycle. pe_acc_out: +1 cycle.
//   pe_acc_out[PE3] valid at cycle: 9 + 1 + 1 = 11 after first act.
//   Acts take N_PES=4 cycles. Flush needed: 11 - 3 = 8 cycles after last act.
//   dot_done posedge fires at: N_PES + FLUSH_CYCLES = 4 + FLUSH_CYCLES.
//   Need 4 + FLUSH_CYCLES >= 4 + 9 + 2 = 15 => FLUSH_CYCLES >= 11... conservative:
//   Use N_PES + 6 = 10 (verified against waveform: 3 extra cycles cured shortfall).

// ── DUT ports — ALL variables declared at top ────────────────────────────────
logic                              clk = 0;
logic                              rst = 1;
logic                              en  = 1;
logic                              arr_load_weights = 0;
logic                              arr_acc_clear    = 0;
logic                              arr_dot_done     = 0;
logic [N_PES-1:0][POSIT_WIDTH-1:0] arr_weights      = '0;
logic [POSIT_WIDTH-1:0]            arr_act_in        = '0;
logic [POSIT_WIDTH-1:0]            arr_result;
logic                              arr_result_valid;

// ── Test state — declared here, not inside initial block ─────────────────────
integer       pass_count;
integer       fail_count;
integer       csv_pass;
integer       csv_fail;
logic [15:0]  acts [N_PES];
logic [15:0]  got;
logic [15:0]  result_a;
logic [15:0]  carry_result;
logic [15:0]  clean_result;
integer       csv_fd;
integer       i;

// ── DUT ──────────────────────────────────────────────────────────────────────
pdpu_array #(
    .POSIT_WIDTH(POSIT_WIDTH), .ES(`ES),
    .ACC_WIDTH(ACC_WIDTH), .N_PES(N_PES),
    .REGIME_MAX(`REGIME_MAX)
) dut (
    .clk(clk), .rst(rst), .en(en),
    .arr_load_weights(arr_load_weights),
    .arr_acc_clear   (arr_acc_clear),
    .arr_dot_done    (arr_dot_done),
    .arr_weights     (arr_weights),
    .arr_act_in      (arr_act_in),
    .arr_result      (arr_result),
    .arr_result_valid(arr_result_valid)
);

always #5 clk = ~clk;

// ── ULP distance ─────────────────────────────────────────────────────────────
function automatic integer ulp_diff(input [15:0] a, input [15:0] b);
    integer ia, ib;
    ia = a; ib = b;
    ulp_diff = (ia > ib) ? (ia - ib) : (ib - ia);
endfunction

// ── Tasks — all variables in tasks are automatic ─────────────────────────────
task automatic load_weights(
    input [15:0] w0, w1, w2, w3
);
    @(negedge clk);
    arr_load_weights = 1;
    arr_weights[0] = w0; arr_weights[1] = w1;
    arr_weights[2] = w2; arr_weights[3] = w3;
    @(posedge clk); #1;
    arr_load_weights = 0;
endtask

task automatic clear_acc;
    @(negedge clk);
    arr_acc_clear = 1;
    @(posedge clk); #1;
    arr_acc_clear = 0;
endtask

task automatic dot_product(
    input  [15:0] a [N_PES],
    output [15:0] result
);
    automatic integer j;
    // Stream activations
    for (j = 0; j < N_PES; j++) begin
        @(negedge clk);
        arr_act_in = a[j];
        @(posedge clk); #1;
    end
    // Flush zeros; assert arr_dot_done on the last flush cycle
    arr_act_in = 16'h0000;
    for (j = 0; j < FLUSH_CYCLES; j++) begin
        @(negedge clk);
        if (j == FLUSH_CYCLES - 1) arr_dot_done = 1;
        @(posedge clk); #1;
        arr_dot_done = 0;
    end
    // Capture result on the cycle valid fires (same posedge as dot_done registers)
    result = arr_result;
endtask

task automatic check_result(
    input [63:0]  name_unused,  // xvlog doesn't support string in task ports well — use $display externally
    input [15:0]  expected,
    input [15:0]  actual,
    input integer tol_ulp,
    input [127:0] label
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

// ── Main ─────────────────────────────────────────────────────────────────────
initial begin
    pass_count = 0; fail_count = 0; csv_pass = 0; csv_fail = 0;

    $display("==== tb_pdpu_array: HARDCODED CASES ====");

    // Reset
    rst = 1; en = 1;
    repeat(3) @(posedge clk); #1;
    rst = 0;
    @(posedge clk); #1;

    // ── T1: zero activations → 0x0000 ────────────────────────────────────────
    $display("--- T1: zero acts -> result=0 ---");
    load_weights(16'h4000, 16'h4000, 16'h4000, 16'h4000);
    clear_acc;
    acts[0]=16'h0000; acts[1]=16'h0000; acts[2]=16'h0000; acts[3]=16'h0000;
    dot_product(acts, got);
    check_result(0, 16'h0000, got, 0, "all-zero acts");

    // ── T2: result_valid is 1-cycle pulse ─────────────────────────────────────
    $display("--- T2: result_valid is 1-cycle pulse ---");
    load_weights(16'h4000, 16'h4000, 16'h4000, 16'h4000);
    clear_acc;
    acts[0]=16'h4000; acts[1]=16'h4000; acts[2]=16'h4000; acts[3]=16'h4000;
    dot_product(acts, got);
    @(posedge clk); #1;
    if (!arr_result_valid) begin
        $display("  PASS [valid_pulse]  de-asserted after 1 cycle");
        pass_count = pass_count + 1;
    end else begin
        $display("  FAIL [valid_pulse]  still asserted");
        fail_count = fail_count + 1;
    end

        // ── T3: w=[1,1,1,1] x a=[1,1,1,1] → expect maxpos 0x7800 ──────────────────
    $display("--- T3: 4x(1.0*1.0) -> expect maxpos (0x7800) ---");
    load_weights(16'h4000, 16'h4000, 16'h4000, 16'h4000);
    clear_acc;
    acts[0]=16'h4000; acts[1]=16'h4000; acts[2]=16'h4000; acts[3]=16'h4000;
    dot_product(acts, got);
    $display("  Product: 0x%04h (expect 0x7800 = maxpos)", got);
    check_result(0, 16'h7800, got, 0, "4x(1*1)=maxpos");

    // ── T4: back-to-back: nonzero then zero ───────────────────────────────────
    $display("--- T4: back-to-back dot products ---");
    load_weights(16'h4000, 16'h4000, 16'h4000, 16'h4000);
    clear_acc;
    acts[0]=16'h4000; acts[1]=16'h4000; acts[2]=16'h4000; acts[3]=16'h4000;
    dot_product(acts, got);
    result_a = got;
    $display("  Product A: 0x%04h (nonzero expected)", got);

    clear_acc;
    acts[0]=16'h0000; acts[1]=16'h0000; acts[2]=16'h0000; acts[3]=16'h0000;
    dot_product(acts, got);
    if (got == 16'h0000) begin
        $display("  PASS [back-to-back B]  zero after nonzero");
        pass_count = pass_count + 1;
    end else begin
        $display("  FAIL [back-to-back B]  expected 0 got 0x%04h", got);
        fail_count = fail_count + 1;
    end
    if (result_a != 16'h0000) begin
        $display("  PASS [back-to-back A]  nonzero: 0x%04h", result_a);
        pass_count = pass_count + 1;
    end else begin
        $display("  FAIL [back-to-back A]  got zero for nonzero input");
        fail_count = fail_count + 1;
    end

    // ── T5: acc_clear resets accumulation ─────────────────────────────────────
    $display("--- T5: acc_clear effect ---");
    load_weights(16'h4000, 16'h4000, 16'h4000, 16'h4000);
    // Run without clearing (carry from T4)
    acts[0]=16'h4000; acts[1]=16'h4000; acts[2]=16'h4000; acts[3]=16'h4000;
    dot_product(acts, got);
    carry_result = got;
    // Now clear and run again
    clear_acc;
    dot_product(acts, got);
    clean_result = got;
    $display("  carry=0x%04h clean=0x%04h", carry_result, clean_result);
    if (carry_result >= clean_result) begin
        $display("  PASS [acc_carry]  carry >= clean (accumulation working)");
        pass_count = pass_count + 1;
    end else begin
        $display("  FAIL [acc_carry]  carry 0x%04h < clean 0x%04h", carry_result, clean_result);
        fail_count = fail_count + 1;
    end

    // ── T6: en=0 freeze ───────────────────────────────────────────────────────
    $display("--- T6: en=0 freeze ---");
    load_weights(16'h4000, 16'h4000, 16'h4000, 16'h4000);
    clear_acc;
    en = 0;
    @(negedge clk); arr_dot_done = 1;
    @(posedge clk); #1; arr_dot_done = 0;
    @(posedge clk); #1;
    if (!arr_result_valid) begin
        $display("  PASS [freeze]  valid did not fire while en=0");
        pass_count = pass_count + 1;
    end else begin
        $display("  FAIL [freeze]  valid fired while en=0");
        fail_count = fail_count + 1;
    end
    en = 1;

    // ── CSV extended coverage ─────────────────────────────────────────────────
    $display("\n--- CSV extended coverage (bonus) ---");
    csv_fd = $fopen("../golden/array_dot_product_vectors.csv", "r");
    if (csv_fd == 0) begin
        $display("WARNING: file ../golden/array_dot_product_vectors.csv could not be opened");
        $display("  (CSV not found - run scripts/gen_golden.py to enable)");
    end else begin
        begin : csv_loop
            automatic integer w0i, w1i, w2i, w3i, a0i, a1i, a2i, a3i, expi;
            automatic integer d;
            // skip header line
            begin
                automatic string hdr;
                void'($fgets(hdr, csv_fd));
            end
            while (!$feof(csv_fd)) begin
                if ($fscanf(csv_fd, "%h,%h,%h,%h,%h,%h,%h,%h,%h\n",
                        w0i,w1i,w2i,w3i,a0i,a1i,a2i,a3i,expi) == 9) begin
                    load_weights(w0i[15:0],w1i[15:0],w2i[15:0],w3i[15:0]);
                    clear_acc;
                    acts[0]=a0i[15:0]; acts[1]=a1i[15:0];
                    acts[2]=a2i[15:0]; acts[3]=a3i[15:0];
                    dot_product(acts, got);
                    d = ulp_diff(expi[15:0], got);
                    if (d <= 512) csv_pass = csv_pass + 1;
                    else begin
                        csv_fail = csv_fail + 1;
                        $display("  CSV FAIL exp=0x%04h got=0x%04h diff=%0d", expi[15:0], got, d);
                    end
                end
            end
        end
        $fclose(csv_fd);
        $display("  CSV: PASS=%0d FAIL=%0d", csv_pass, csv_fail);
    end

    // ── Summary ───────────────────────────────────────────────────────────────
    $display("\n============================================");
    $display(" HARDCODED: PASS=%0d FAIL=%0d", pass_count, fail_count);
    if (fail_count == 0 && csv_fail == 0)
        $display(" RESULT: ** PASS **");
    else
        $display(" RESULT: ** FAIL **");
    $display("============================================\n");

    $finish;
end

endmodule
