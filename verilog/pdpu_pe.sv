`timescale 1ns/1ps
`include "posit_defines.svh"

// ============================================================================
// pdpu_pe.sv — Processing Element with hybrid DSP-assisted multiplier
//
// CHANGES FROM ORIGINAL:
//   - Instantiates hybrid_posit_mult instead of pdpu_mitchell_mult
//   - Everything else is IDENTICAL (accumulator, activation shift, control)
// ============================================================================

module pdpu_pe #(
    parameter POSIT_WIDTH = `POSIT_WIDTH,
    parameter ES          = `ES,
    parameter ACC_WIDTH   = `ACC_WIDTH,
    parameter REGIME_MAX  = `REGIME_MAX
)(
    input  wire                   clk,
    input  wire                   rst,
    input  wire                   en,
    input  wire                   pe_load_weight,
    input  wire                   pe_acc_clear,
    input  wire [POSIT_WIDTH-1:0] pe_weight_in,
    input  wire [POSIT_WIDTH-1:0] pe_act_in,
    output reg  [POSIT_WIDTH-1:0] pe_act_out,
    output reg  [ACC_WIDTH-1:0]   pe_acc_out,
    output reg                    pe_acc_valid
);

reg [POSIT_WIDTH-1:0] weight_r;
reg [ACC_WIDTH-1:0]   acc_r;
reg [POSIT_WIDTH-1:0] act_pipe_r;

wire [POSIT_WIDTH-1:0] mult_result;
wire                   mult_valid;

// ── Multiplier: hybrid DSP-assisted (was pdpu_mitchell_mult) ──────────────
hybrid_posit_mult #(
    .POSIT_WIDTH(POSIT_WIDTH), .ES(ES), .REGIME_MAX(REGIME_MAX)
) u_mult (
    .clk(clk), .rst(rst), .en(en),
    .mult_a(weight_r),
    .mult_b(act_pipe_r),
    .mult_result(mult_result),
    .mult_valid(mult_valid)
);

// Sign-extend mult_result (Posit16) to ACC_WIDTH (32 bits)
wire [ACC_WIDTH-1:0] mult_extended =
    {{(ACC_WIDTH-POSIT_WIDTH){mult_result[POSIT_WIDTH-1]}}, mult_result};

// ── Everything below is UNCHANGED from original pdpu_pe.sv ────────────────
always_ff @(posedge clk) begin
    if (rst) begin
        weight_r     <= {POSIT_WIDTH{1'b0}};
        acc_r        <= {ACC_WIDTH{1'b0}};
        act_pipe_r   <= {POSIT_WIDTH{1'b0}};
        pe_act_out   <= {POSIT_WIDTH{1'b0}};
        pe_acc_out   <= {ACC_WIDTH{1'b0}};
        pe_acc_valid <= 1'b0;
    end else if (en) begin
        // 1-hop activation shift
        act_pipe_r <= pe_act_in;
        pe_act_out <= act_pipe_r;

        // Weight load
        if (pe_load_weight)
            weight_r <= pe_weight_in;

        // Accumulator
        if (pe_acc_clear) begin
            acc_r      <= {ACC_WIDTH{1'b0}};
            act_pipe_r <= {POSIT_WIDTH{1'b0}};
        end else if (mult_valid) begin
            acc_r <= acc_r + mult_extended;
        end

        pe_acc_out   <= acc_r;
        pe_acc_valid <= 1'b0;
    end
end

endmodule
