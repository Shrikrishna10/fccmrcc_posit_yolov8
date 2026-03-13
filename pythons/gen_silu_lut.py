#!/usr/bin/env python3
"""
gen_silu_lut.py — Generate SiLU activation lookup table for Posit16
Produces silu_lut.hex for $readmemh loading in silu_lut.sv

SiLU(x) = x * sigmoid(x) = x / (1 + exp(-x))

ADDRESSING SCHEME (must match silu_lut.sv):
  The Verilog module uses:  lut_addr = posit_in[15:8]  (top 8 bits, 256 entries)
  
  This means bit 15 (sign bit) is part of the address:
    addr 0x00..0x7F → positive posit values (sign=0)
    addr 0x80..0xFF → negative posit values (sign=1)
  
  For positive x: SiLU(x) ≈ x for large x, ≈ x*sigmoid(x) for small x
  For negative x: SiLU(x) → 0 as x → -∞, and SiLU(x) ≈ -0.278 at x ≈ -1.28

NOTE ON PRECISION:
  Each LUT entry covers a 256-value bucket of Posit16 encodings.
  We use the bucket midpoint (addr<<8 | 0x80) as the representative input.
  addr=0x00 covers posit16 values 0x0000..0x00FF. The midpoint 0x0080 decodes
  to a small positive value (~0.016), NOT zero. This is expected — the LUT
  gives a reasonable approximation for the entire bucket, not exact results
  for the bucket boundaries.
"""

import math
import os
import sys

# Import Posit16 class from sibling module
try:
    from .gen_golden_vectors import Posit16, POSIT_WIDTH
except ImportError:
    # Fallback for direct script execution (python gen_silu_lut.py)
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from gen_golden_vectors import Posit16, POSIT_WIDTH


def silu(x: float) -> float:
    """Compute SiLU(x) = x * sigmoid(x)."""
    if x > 20:
        return x  # sigmoid ≈ 1
    elif x < -20:
        return 0.0  # sigmoid ≈ 0
    return x / (1.0 + math.exp(-x))


def generate_silu_lut(output_dir: str = "."):
    """Generate 256-entry SiLU LUT in Posit16 format.
    
    Addressing: addr = posit16_input[15:8] (top 8 bits including sign).
    This matches silu_lut.sv with ADDR_BITS=8, LUT_DEPTH=256.
    """
    LUT_DEPTH = 256
    ADDR_BITS = 8
    filepath = os.path.join(output_dir, "silu_lut.hex")

    print(f"Generating SiLU LUT ({LUT_DEPTH} entries, {ADDR_BITS}-bit addr) -> {filepath}")

    entries = []
    for addr in range(LUT_DEPTH):
        # Reconstruct representative Posit16 input from address
        # addr = posit16[15:8], so posit16 ≈ addr << 8
        # We use the midpoint of each 256-value bucket for better accuracy
        posit_bits = (addr << 8) | 0x80  # midpoint: addr*256 + 128

        # Decode to float
        input_val = Posit16.decode(posit_bits)

        if math.isnan(input_val):
            # NaR → output zero (safe default for inference)
            output_bits = Posit16.ZERO
        elif abs(input_val) < 1e-30:
            output_bits = Posit16.ZERO
        else:
            output_val = silu(input_val)
            output_bits = Posit16.encode(output_val)

        entries.append(output_bits)

    # Write hex file (no comment lines — some $readmemh parsers are strict)
    with open(filepath, 'w') as f:
        for val in entries:
            f.write(f"{val:04X}\n")

    # Also write a human-readable CSV for verification
    csv_filepath = os.path.join(output_dir, "silu_lut_debug.csv")
    with open(csv_filepath, 'w') as f:
        f.write("addr,input_hex,input_value,silu_value,output_hex,output_value\n")
        for addr in range(LUT_DEPTH):
            posit_in = (addr << 8) | 0x80
            val_in = Posit16.decode(posit_in)
            if math.isnan(val_in):
                silu_val = 0.0
            else:
                silu_val = silu(val_in)
            val_out = Posit16.decode(entries[addr])
            f.write(f"{addr},0x{posit_in:04X},{val_in:.6f},{silu_val:.6f},"
                    f"0x{entries[addr]:04X},{val_out:.6f}\n")

    # Print sample entries for verification
    print(f"  Also wrote debug CSV: {csv_filepath}")
    print(f"  Entry 0x00 (near-zero): 0x{entries[0x00]:04X} = {Posit16.decode(entries[0x00]):.6f}")
    print(f"  Entry 0x40 (~1.0):      0x{entries[0x40]:04X} = {Posit16.decode(entries[0x40]):.4f}")
    print(f"  Entry 0x50 (~2.0):      0x{entries[0x50]:04X} = {Posit16.decode(entries[0x50]):.4f}")
    print(f"  Entry 0x80 (NaR):       0x{entries[0x80]:04X} (NaR -> 0)")
    print(f"  Entry 0xC0 (~-1.0):     0x{entries[0xC0]:04X} = {Posit16.decode(entries[0xC0]):.4f}")

    # Sanity checks (relaxed — bucket midpoints, not exact values)
    # Large positive input → SiLU ≈ identity, so output should be large positive
    val_7f = Posit16.decode(entries[0x7F])
    assert val_7f > 0, f"SiLU(large positive) should be positive, got {val_7f}"
    # NaR entry should be zero (safe default)
    assert entries[0x80] == Posit16.ZERO, f"NaR entry should be 0, got 0x{entries[0x80]:04X}"
    # Negative inputs: SiLU(-large) → 0
    assert Posit16.decode(entries[0xFF]) >= -0.05, \
        f"SiLU(large negative) should be near 0, got {Posit16.decode(entries[0xFF])}"
    print("  Sanity checks passed.")

    return entries


if __name__ == "__main__":
    output_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    generate_silu_lut(output_dir)
    print("[OK] SiLU LUT generated (256 entries, 8-bit addressing)")
