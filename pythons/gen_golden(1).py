#!/usr/bin/env python3
"""
gen_golden.py
Generates all golden reference files for the PDPU testbench suite.

REQUIRES:
    pip install softposit numpy

OUTPUTS (all written to ../golden/):
    mitchell_mult_vectors.csv     - 10,000 (a, b, expected_product) Posit16 pairs
    approx_adder_vectors.csv      - 10,000 (a, b, expected_sum) Posit16 pairs
    pe_vectors.csv                - dot product test cases for pdpu_pe
    array_vectors.csv             - 4-PE dot product test cases
    reduction_tree_vectors.csv    - N_PES accumulator -> Posit16 sum cases
    mitchell_corr_lut.hex         - 1024-entry correction LUT for $readmemh

USAGE:
    cd scripts/
    python3 gen_golden.py

All values written as 4-digit hex (Posit16 bit patterns).
"""

import os
import random
import struct
import numpy as np

try:
    import softposit as sp
except ImportError:
    raise SystemExit(
        "softposit not found. Install with: pip install softposit\n"
        "If unavailable, use the pre-generated CSVs in golden/ (see README)."
    )

OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "golden")
os.makedirs(OUT_DIR, exist_ok=True)

random.seed(42)
np.random.seed(42)

# ---------------------------------------------------------------------------
# Posit16 helpers via softposit
# ---------------------------------------------------------------------------
def rand_posit16():
    """Return a random non-special Posit16 value (not zero, not NaR)."""
    while True:
        bits = random.randint(1, 0x7FFF)  # positive non-zero non-NaR
        if bits not in (0x0000, 0x8000):
            return sp.posit16(bits=bits)

def posit16_bits(p):
    """Extract raw 16-bit integer from softposit posit16 object."""
    return int(p.bits)

def hex4(val):
    return f"{int(val) & 0xFFFF:04x}"

# ---------------------------------------------------------------------------
# 1. Mitchell multiplier golden vectors
# ---------------------------------------------------------------------------
print("Generating mitchell_mult_vectors.csv ...")
mult_path = os.path.join(OUT_DIR, "mitchell_mult_vectors.csv")
with open(mult_path, "w") as f:
    f.write("a_hex,b_hex,expected_hex\n")
    # Special cases first
    for a_bits, b_bits, exp_bits in [
        (0x0000, 0x3C00, 0x0000),  # 0 * x = 0
        (0x3C00, 0x0000, 0x0000),  # x * 0 = 0
        (0x8000, 0x3C00, 0x8000),  # NaR * x = NaR
        (0x3C00, 0x8000, 0x8000),  # x * NaR = NaR
        (0x8000, 0x8000, 0x8000),  # NaR * NaR = NaR
    ]:
        f.write(f"{hex4(a_bits)},{hex4(b_bits)},{hex4(exp_bits)}\n")
    # Random pairs
    mre_sum = 0.0
    count = 10000
    for _ in range(count):
        a = rand_posit16()
        b = rand_posit16()
        prod = a * b
        f.write(f"{hex4(posit16_bits(a))},{hex4(posit16_bits(b))},{hex4(posit16_bits(prod))}\n")
        # Track MRE for info
        fa, fb, fp = float(a), float(b), float(prod)
        ref = fa * fb
        if ref != 0:
            mre_sum += abs(fp - ref) / abs(ref)
print(f"  Written {count+5} vectors. Exact Posit16 MRE={mre_sum/count*100:.3f}% (reference, should be 0)")

# ---------------------------------------------------------------------------
# 2. Approx adder golden vectors
# ---------------------------------------------------------------------------
print("Generating approx_adder_vectors.csv ...")
add_path = os.path.join(OUT_DIR, "approx_adder_vectors.csv")
with open(add_path, "w") as f:
    f.write("a_hex,b_hex,expected_hex\n")
    for a_bits, b_bits, label in [
        (0x0000, 0x3C00, "zero+x"),
        (0x3C00, 0x0000, "x+zero"),
        (0x8000, 0x3C00, "NaR+x"),
        (0x3C00, 0x8000, "x+NaR"),
    ]:
        a = sp.posit16(bits=a_bits)
        b = sp.posit16(bits=b_bits)
        s = a + b
        f.write(f"{hex4(a_bits)},{hex4(b_bits)},{hex4(posit16_bits(s))}\n")
    # Cancellation: x + (-x) = 0
    for _ in range(10):
        a = rand_posit16()
        neg_a_bits = (~posit16_bits(a) + 1) & 0xFFFF  # 2's complement negation
        f.write(f"{hex4(posit16_bits(a))},{hex4(neg_a_bits)},{hex4(0)}\n")
    # Random pairs
    for _ in range(10000):
        a = rand_posit16()
        b = rand_posit16()
        s = a + b
        f.write(f"{hex4(posit16_bits(a))},{hex4(posit16_bits(b))},{hex4(posit16_bits(s))}\n")
print("  Written 10,014 vectors.")

# ---------------------------------------------------------------------------
# 3. PE dot product vectors
# ---------------------------------------------------------------------------
print("Generating pe_vectors.csv ...")
pe_path = os.path.join(OUT_DIR, "pe_vectors.csv")
with open(pe_path, "w") as f:
    f.write("# weight_hex, num_acts, act0_hex ... actN_hex, expected_acc_hex (32-bit signed)\n")
    f.write("weight_hex,acts_hex_space_separated,expected_acc_dec\n")
    for _ in range(200):
        w = rand_posit16()
        length = random.randint(4, 32)
        acts = [rand_posit16() for _ in range(length)]
        # Reference: sum of (w * a) for each a, using softposit exact
        acc = 0
        for a in acts:
            prod_bits = posit16_bits(w * a)
            # Sign-extend to 32-bit
            if prod_bits & 0x8000:
                prod_bits |= 0xFFFF0000
            prod_signed = struct.unpack('>i', struct.pack('>I', prod_bits & 0xFFFFFFFF))[0]
            acc += prod_signed
        # Clamp to 32-bit signed
        acc = max(-2**31, min(2**31 - 1, acc))
        acts_hex = " ".join(hex4(posit16_bits(a)) for a in acts)
        f.write(f"{hex4(posit16_bits(w))},{acts_hex},{acc}\n")
print("  Written 200 PE dot product test cases.")

# ---------------------------------------------------------------------------
# 4. 4-PE array dot product vectors
# ---------------------------------------------------------------------------
print("Generating array_vectors.csv ...")
arr_path = os.path.join(OUT_DIR, "array_vectors.csv")
N_PES = 4
with open(arr_path, "w") as f:
    f.write("# weights[0..3], activation_vector, expected Posit16 result\n")
    f.write("w0,w1,w2,w3,acts_hex_space_separated,expected_result_hex\n")
    for _ in range(100):
        weights = [rand_posit16() for _ in range(N_PES)]
        length = random.randint(4, 16) * N_PES  # multiple of N_PES for clean sweep
        acts = [rand_posit16() for _ in range(length)]
        # Reference: sum over all i of weights[i % N_PES] * acts[j*N_PES + i]
        total = sp.posit16(0.0)
        for j in range(length // N_PES):
            for i in range(N_PES):
                total = total + weights[i] * acts[j * N_PES + i]
        w_hex = ",".join(hex4(posit16_bits(w)) for w in weights)
        acts_hex = " ".join(hex4(posit16_bits(a)) for a in acts)
        f.write(f"{w_hex},{acts_hex},{hex4(posit16_bits(total))}\n")
print("  Written 100 array dot product test cases.")

# ---------------------------------------------------------------------------
# 5. Reduction tree vectors
# ---------------------------------------------------------------------------
print("Generating reduction_tree_vectors.csv ...")
rt_path = os.path.join(OUT_DIR, "reduction_tree_vectors.csv")
with open(rt_path, "w") as f:
    f.write("# N_PES 32-bit signed integer accumulators -> expected Posit16 output\n")
    f.write("acc0,acc1,acc2,acc3,expected_hex\n")
    # All-zero
    f.write(f"0,0,0,0,{hex4(0)}\n")
    # One large, rest zero
    f.write(f"32767,0,0,0,{hex4(posit16_bits(sp.posit16(32767.0)))}\n")
    # Random
    for _ in range(500):
        accs = [random.randint(-32768, 32767) for _ in range(N_PES)]
        total = sum(accs)
        p = sp.posit16(float(total))
        f.write(",".join(str(a) for a in accs) + f",{hex4(posit16_bits(p))}\n")
print("  Written 502 reduction tree test cases.")

# ---------------------------------------------------------------------------
# 6. Mitchell correction LUT
# Top 5 bits of frac_a x top 5 bits of frac_b -> floor(fA * fB * 2^11)
# Index = {frac_a[4:0], frac_b[4:0]} = 10-bit = 1024 entries
# Each entry = 11 bits (FRAC_W), written as 3 hex digits
# ---------------------------------------------------------------------------
print("Generating mitchell_corr_lut.hex ...")
lut_path = os.path.join(OUT_DIR, "mitchell_corr_lut.hex")
FRAC_W = 11
LUT_IDX = 5
with open(lut_path, "w") as f:
    for idx in range(1 << (2 * LUT_IDX)):
        fa_top = (idx >> LUT_IDX) & ((1 << LUT_IDX) - 1)
        fb_top = idx & ((1 << LUT_IDX) - 1)
        # fA in [0,1): fa_top / 2^LUT_IDX
        fA = fa_top / (1 << LUT_IDX)
        fB = fb_top / (1 << LUT_IDX)
        # Correction in fixed-point Q0.FRAC_W
        corr = int(fA * fB * (1 << FRAC_W))
        corr = min(corr, (1 << FRAC_W) - 1)
        f.write(f"{corr:03x}\n")
print(f"  Written 1024-entry LUT ({1<<(2*LUT_IDX)} entries, 3 hex digits each).")

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print("\n=== Golden vector generation complete ===")
print(f"Output directory: {os.path.abspath(OUT_DIR)}")
print("Files:")
for fname in sorted(os.listdir(OUT_DIR)):
    fpath = os.path.join(OUT_DIR, fname)
    print(f"  {fname:40s}  {os.path.getsize(fpath):>8d} bytes")
print("\nNext step: run xsim testbenches. Each testbench reads its CSV via $fopen/$fscanf.")
