# RTL Package — Hybrid DSP-Assisted Posit16 PDPU Array

## Quick Start for Person A

### Files in this package

| File | Status | What it does |
|------|--------|-------------|
| `posit_defines.svh` | **MODIFIED** | Added N_BANKS=8, N_PES=16, USE_DSP_HYBRID flag |
| `hybrid_posit_mult.sv` | **NEW** (replaces `pdpu_mitchell_mult.v`) | DSP-assisted Posit16 multiplier. Decode/encode PRESERVED from original. Mitchell fraction approx REPLACED with exact 11×11 DSP multiply. |
| `pdpu_pe.sv` | **MODIFIED** (2 lines changed) | Instantiates `hybrid_posit_mult` instead of `pdpu_mitchell_mult`. Everything else identical. |
| `pdpu_reduction_tree.sv` | **MODIFIED** | Parameterized binary adder tree via generate. Works for any power-of-2 N_PES (was hardcoded for 4). CLZ + Posit16 encode unchanged. |
| `pdpu_array_banked.sv` | **NEW** (replaces `pdpu_array.sv`) | N_BANKS × N_PES generate-based array. Each bank has independent weights, shared activation stream. |
| `silu_lut.sv` | **NEW** | 256-entry SiLU activation ROM. 1 BRAM18 or distributed RAM. |
| `silu_lut.hex` | **NEW** | Pre-generated SiLU lookup table (256 Posit16 entries) |
| `gen_silu_lut.py` | **NEW** | Python script that generates silu_lut.hex |
| `posit16_int16_convert.sv` | **NEW** | Posit16↔INT16 converters for PS-PL boundary |
| `tb_hybrid_array.sv` | **NEW** | Testbench for the banked array (replaces `tb_pdpu_array.sv`) |

### What Person A needs to DO vs what's DONE

**Already done (in this package):**
- [x] Task A1: Hybrid PE multiply (hybrid_posit_mult.sv)
- [x] Task A2: Parameterized array with generate (pdpu_array_banked.sv)
- [x] Task A3: SiLU LUT (silu_lut.sv + silu_lut.hex)
- [x] Task A2 part: Parameterized reduction tree (pdpu_reduction_tree.sv)
- [x] Boundary converters for Person C (posit16_int16_convert.sv)

**Person A still needs to:**
- [ ] A4: Run Vivado synthesis on 16-PE config, check resources + timing
- [ ] A5: Run Vivado synthesis on 128-PE config (8×16), check resources
- [ ] A6: Fix any timing violations (may need pipeline stage insertion)
- [ ] A7: Add ILA debug probes for Person C's integration
- [ ] A8: RTL cleanup, documentation, testbench finalization
- [ ] Validate hybrid_posit_mult against SoftPosit golden vectors (from Person B)

### Simulation steps (Vivado xsim)

```bash
# 1. Create simulation project with these files:
#    posit_defines.svh, hybrid_posit_mult.sv, pdpu_pe.sv,
#    pdpu_reduction_tree.sv, pdpu_array_banked.sv, tb_hybrid_array.sv
#    Also include: silu_lut.sv, silu_lut.hex

# 2. For quick test (2 banks × 4 PEs):
#    tb_hybrid_array.sv uses localparam overrides (N_BANKS=2, N_PES=4)
#    Run as-is for functional verification.

# 3. For full-scale test (8 banks × 16 PEs):
#    Modify tb_hybrid_array.sv localparams to N_BANKS=8, N_PES=16
#    Or better: create a separate tb for full-scale with CSV golden vectors.

# 4. Synthesis quick-check:
#    Open Vivado, create RTL project targeting xczu7ev-ffvc1156-2-e
#    Add all .sv + .svh files
#    Run synthesis → check utilization report
```

### Key architecture decisions embedded in the code

1. **DSP inference**: `hybrid_posit_mult.sv` line ~120: `sig_product = sig_a * sig_b`
   Vivado infers DSP48E2 from this 12×12 unsigned multiply. No explicit DSP instantiation needed.
   If you want explicit control, replace with a DSP48E2 primitive instantiation.

2. **Accumulation stays in LUTs**: The PE accumulator (`acc_r <= acc_r + mult_extended`) is a
   32-bit integer add that Vivado maps to carry chains (LUTs+CARRY8). NOT DSP.
   This is intentional — the DSP's 48-bit accumulator can't be used here because
   the Posit16 multiplication result needs sign-extension before accumulation.

3. **Scale computation stays in LUTs**: The `scale_a + scale_b` path is Mitchell's log-domain
   insight. This is 6-bit integer arithmetic — tiny in LUTs, no benefit from DSP.

4. **N_BANKS=8 means 8 output channels computed simultaneously**. The layer controller (Person C's
   job) loads 8 different weight sets and gets 8 results per dot-product completion.

### Compatibility note

The old `pdpu_mitchell_mult.v` and `pdpu_array.sv` are NOT needed anymore.
If you want to keep them for comparison/testing, rename them to `*_legacy.*`.
The testbench `tb_pdpu_array.sv` won't work with the new banked array (different ports).
Use `tb_hybrid_array.sv` instead.
