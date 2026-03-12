`ifndef POSIT_DEFINES_SVH
`define POSIT_DEFINES_SVH

// ── Posit format ──────────────────────────────────────────────────────────────
`define POSIT_WIDTH  16
`define ES           1
`define REGIME_MAX   3          // k clamped to [-3, +3]
`define USEED        4          // 2^(2^ES) = 4

// ── Accumulator ───────────────────────────────────────────────────────────────
`define ACC_WIDTH    32

// ── Array (Banked architecture for output parallelism) ────────────────────────
// Tm = N_BANKS  = output-channel parallelism (each bank has independent weights)
// Tn = N_PES    = input-channel parallelism (PEs per bank, share activation stream)
// Total PEs     = N_BANKS × N_PES
//
// Scaling guide (ZCU104 XCZU7EV):
//   Config       PEs   DSPs(7%)  LUTs(est)  Peak GOPS @200MHz
//   1×4   (T2)     4     4        ~1.6K       0.8
//   1×16  (T2b)   16    16        ~6.4K       3.2
//   4×16  (T3a)   64    64       ~25.6K      12.8
//   8×16  (T3b)  128   128       ~51.2K      25.6   ← TARGET
//  16×16  (max)  256   256      ~102.4K      51.2
`define N_BANKS      8          // Output parallelism (Tm) — 8 output channels/cycle
`define N_PES        16         // Input parallelism per bank (Tn)
`define N_PES_TOTAL  (`N_BANKS * `N_PES)

// ── Im2col ────────────────────────────────────────────────────────────────────
`define KERNEL_MAX   3
`define MAX_CIN      512

// ── BRAM ──────────────────────────────────────────────────────────────────────
`define BRAM_ADDR_W  16
`define BRAM_DATA_W  `POSIT_WIDTH

// ── Special values ────────────────────────────────────────────────────────────
`define POSIT_ZERO   16'h0000
`define POSIT_NAR    16'h8000

// ── Saturation policy ─────────────────────────────────────────────────────────
`define POSIT_MAXPOS 16'h7F00
`define POSIT_MINPOS 16'h0100

// ── Multiplier mode ───────────────────────────────────────────────────────────
// DSP_HYBRID: Uses DSP48E2 for exact 11×11 fraction multiply.
//             Log-domain scale computation stays in LUTs (Mitchell insight).
//             Set to 0 to fall back to pure Mitchell LUT approximation.
`define USE_DSP_HYBRID 1

// ── Reset / flow control ──────────────────────────────────────────────────────
// rst : active-high synchronous
// en  : active-high enable per stage — sole flow control, no backpressure

`endif // POSIT_DEFINES_SVH
