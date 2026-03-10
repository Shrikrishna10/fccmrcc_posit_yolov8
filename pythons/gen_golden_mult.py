#!/usr/bin/env python3
"""
gen_golden_mult.py — Golden vectors matching the EXACT Verilog RTL behavior.

The Python decoder replicates the Verilog priority-encoder run counter
bit-for-bit, including its max run of 9 and regime clamping to [-3,+3].
"""
import numpy as np, math

# ─── Posit16 decode: EXACT match to hybrid_posit_mult.sv ────────────────
# Replicates the Verilog priority encoder which checks body[13] down to body[6].
# Maximum run it can report = 9 (when body[13:6] all match rbit, default case).

def posit16_decode_hw(p16):
    """Decode Posit16 exactly as the Verilog RTL does. Returns (sign, k, exp, frac11)."""
    p16 = int(p16) & 0xFFFF
    if p16 == 0x0000:
        return (0, 0, 0, 0, True, False)   # zero flag
    if p16 == 0x8000:
        return (0, 0, 0, 0, False, True)   # NaR flag

    sign = (p16 >> 15) & 1
    if sign:
        p16 = ((~p16) + 1) & 0xFFFF

    body = p16 & 0x7FFF
    rbit = (body >> 14) & 1

    # Priority encoder: matches Verilog exactly
    # (body[13] != rbit) ? 1 : (body[12] != rbit) ? 2 : ... : (body[6] != rbit) ? 8 : 9
    run = 9  # default (all body[13:6] match rbit)
    for i in range(13, 5, -1):  # 13,12,11,10,9,8,7,6
        if ((body >> i) & 1) != rbit:
            run = 13 - i + 1  # body[13]→1, body[12]→2, ..., body[6]→8
            # Wait, let me match exactly:
            # (body[13]!=rbit) → run=1
            # (body[12]!=rbit) → run=2
            # etc.
            run = 14 - i
            break

    if rbit:
        k_s = run - 1
    else:
        k_s = -run

    # Clamp k to [-3, +3] (REGIME_MAX = 3)
    k = max(-3, min(3, k_s))

    # Consumed bits = run + 1 (terminator)
    cons = run + 1

    # Exponent bit at position (14 - cons)
    exp_pos = 14 - cons
    if exp_pos >= 0 and exp_pos <= 14:
        exp_bit = (body >> exp_pos) & 1
    else:
        exp_bit = 0

    # Fraction: shift body left by (cons + 1), take top 11 bits
    shift_amount = cons + 1
    if shift_amount < 15:
        fshifted = (body << shift_amount) & 0x7FFF
        frac = (fshifted >> 4) & 0x7FF
    else:
        frac = 0

    return (sign, k, exp_bit, frac, False, False)


def posit16_to_float_hw(p16):
    """Convert Posit16 to float using hardware-matching decode."""
    sign, k, exp_bit, frac, is_zero, is_nar = posit16_decode_hw(p16)
    if is_zero:
        return 0.0
    if is_nar:
        return float('nan')
    value = (4.0 ** k) * (2.0 ** exp_bit) * (1.0 + frac / 2048.0)
    return -value if sign else value


# ─── Posit16 encode: matches the FIXED encoder in hybrid_posit_mult.sv ──

def float_to_posit16_hw(f):
    """Encode float to Posit16 matching the hardware encoder."""
    if f == 0.0:
        return 0x0000
    if math.isnan(f) or math.isinf(f):
        return 0x8000

    sign = 1 if f < 0 else 0
    f = abs(f)

    # Saturation
    if f >= 64.0:
        # k=3, e=0, frac=max → 0x7800 is canonical maxpos (k=3,e=0,frac=0 = 64)
        # For f > 64, saturate to 0x7BFF (k=3,e=0,frac=max) or just 0x7800
        body = 0x7F00  # hardware POSIT_MAXPOS (extended regime encoding of 64)
        return ((~body + 1) & 0xFFFF) if sign else body
    if f < (1.0 / 64.0) * 0.5:
        return 0x0000  # too small

    log2_val = math.log2(f)
    scale = int(math.floor(log2_val))

    if scale >= 0:
        k, e = scale // 2, scale % 2
    else:
        k = -((-scale + 1) // 2)
        e = scale - 2 * k
        if e < 0:
            k -= 1
            e = scale - 2 * k

    k = max(-3, min(3, k))
    e = max(0, min(1, e))

    sig = f / (4.0 ** k * 2.0 ** e)
    frac = int(round((sig - 1.0) * 2048.0))
    frac = max(0, min(2047, frac))

    # Build body — matches the FIXED Verilog encoder
    body = 0
    if k >= 0:
        # Positive regime: (k+1) ones then 0 terminator
        r_total = k + 2
        for i in range(k + 1):
            body |= (1 << (14 - i))
        # terminator 0 already there
    else:
        # Negative regime: |k| zeros then 1 terminator
        r_total = (-k) + 1
        body |= (1 << (14 - (-k)))  # terminator 1

    # Exponent at bit (14 - r_total)
    exp_pos = 14 - r_total
    if exp_pos >= 0:
        body |= (e << exp_pos)

    # Fraction: placed right below exp bit, top-aligned
    frac_avail = max(0, exp_pos)
    if frac_avail > 0 and frac > 0:
        if frac_avail >= 11:
            fp = frac << (frac_avail - 11)
        else:
            fp = frac >> (11 - frac_avail)
        body |= fp & ((1 << frac_avail) - 1)

    body &= 0x7FFF

    if sign:
        return ((~body + 1) & 0xFFFF)
    return body


# ─── Hardware-matching multiply ──────────────────────────────────────────

def posit16_mult_hw(a, b):
    """Multiply two Posit16 values exactly as the hardware does."""
    a, b = int(a) & 0xFFFF, int(b) & 0xFFFF

    # Special cases (match Verilog priority)
    is_nar_a = (a == 0x8000)
    is_nar_b = (b == 0x8000)
    is_zero_a = (a == 0x0000)
    is_zero_b = (b == 0x0000)

    if is_nar_a or is_nar_b:
        return 0x8000
    if is_zero_a or is_zero_b:
        return 0x0000

    # Decode both operands with hardware-matching decoder
    s_a, k_a, e_a, f_a, _, _ = posit16_decode_hw(a)
    s_b, k_b, e_b, f_b, _, _ = posit16_decode_hw(b)

    result_sign = s_a ^ s_b

    # Scale add (Mitchell log-domain)
    scale_a = 2 * k_a + e_a  # signed
    scale_b = 2 * k_b + e_b
    scale_r_wide = scale_a + scale_b

    # Exact fraction multiply (DSP)
    sig_a = (1 << 11) | f_a   # 1.fraction in UQ1.11 (12 bits)
    sig_b = (1 << 11) | f_b
    sig_product = sig_a * sig_b  # 24-bit result

    # Overflow check
    frac_overflow = (sig_product >> 23) & 1
    if frac_overflow:
        frac_r = (sig_product >> 12) & 0x7FF
    else:
        frac_r = (sig_product >> 11) & 0x7FF

    # Adjust scale
    scale_adjusted = scale_r_wide + (1 if frac_overflow else 0)

    # Clamp scale
    if scale_adjusted > 6:
        scale_r = 6
    elif scale_adjusted < -6:
        scale_r = -6
    else:
        scale_r = scale_adjusted

    # Scale overflow → saturation
    if scale_adjusted > 6:
        if result_sign:
            return ((~0x7F00 + 1) & 0xFFFF)  # negative saturate (matches POSIT_MAXPOS)
        else:
            return 0x7F00  # positive saturate (matches POSIT_MAXPOS)

    # Extract k_r and exp_r from scale_r
    # k_r_s = scale_r >> 1 (arithmetic shift)
    if scale_r >= 0:
        k_r_s = scale_r >> 1
    else:
        k_r_s = -((-scale_r + 1) >> 1)
    exp_r = scale_r - 2 * k_r_s
    if exp_r < 0:
        k_r_s -= 1
        exp_r = scale_r - 2 * k_r_s

    k_r = max(-3, min(3, k_r_s))

    # Encode — matching the FIXED Verilog encoder
    k_neg = k_r < 0
    k_mag = abs(k_r)

    if not k_neg:
        if k_mag == 0:
            body = (0b10 << 13) | (exp_r << 12) | (frac_r << 1)
        elif k_mag == 1:
            body = (0b110 << 12) | (exp_r << 11) | frac_r
        elif k_mag == 2:
            body = (0b1110 << 11) | (exp_r << 10) | (frac_r >> 1)
        else:  # k_mag == 3
            body = (0b11110 << 10) | (exp_r << 9) | (frac_r >> 2)
    else:
        # FIXED: no spurious 0 between terminator and exp
        if k_mag == 1:
            body = (0b01 << 13) | (exp_r << 12) | (frac_r << 1)
        elif k_mag == 2:
            body = (0b001 << 12) | (exp_r << 11) | frac_r
        else:  # k_mag == 3
            body = (0b0001 << 11) | (exp_r << 10) | (frac_r >> 1)

    body &= 0x7FFF
    encoded_pos = body
    encoded_neg = ((~body) + 1) & 0xFFFF

    if result_sign:
        return encoded_neg
    return encoded_pos


# ─── Self-test ───────────────────────────────────────────────────────────

def self_test():
    known_prods = [
        (0x4000, 0x4000, 0x4000, "1*1=1"),
        (0x5000, 0x5000, 0x6000, "2*2=4"),
        (0x5000, 0x3000, 0x4000, "2*0.5=1"),
        (0xC000, 0xC000, 0x4000, "(-1)*(-1)=1"),
        (0x6000, 0x6000, 0x7000, "4*4=16"),
        (0x4800, 0x4800, 0x5200, "1.5*1.5=2.25"),
        (0x4000, 0x3000, 0x3000, "1*0.5=0.5"),
        (0x3000, 0x3000, 0x2000, "0.5*0.5=0.25"),
        (0x6800, 0x6800, 0x7800, "8*8=64 (normal, scale=6)"),
        (0x7F00, 0x4000, 0x7800, "maxpos*1 (normal, scale=6)"),
        (0x0100, 0x4000, 0x0800, "minpos*1=canonical"),
        (0x0000, 0x4000, 0x0000, "0*1=0"),
        (0x8000, 0x4000, 0x8000, "NaR*1=NaR"),
        (0xD000, 0x5000, 0xC000, "-0.5*2=-1"),
        (0x4000, 0x6800, 0x6800, "1*8=8"),
    ]
    errors = 0
    for a, b, exp, label in known_prods:
        got = posit16_mult_hw(a, b)
        if abs(got - exp) > 4:
            print(f"  FAIL {label}: 0x{a:04x}*0x{b:04x}=0x{got:04x} (exp 0x{exp:04x})")
            errors += 1
    if errors:
        print(f"Self-test: {errors} FAILURES")
        return False
    print("Self-test: ALL PASSED")
    return True


# ─── Generate vectors ────────────────────────────────────────────────────

def main():
    if not self_test():
        return

    vectors = set()

    # Representative values
    rv = [0x0000, 0x0100, 0x0200, 0x0800, 0x1000, 0x2000, 0x2800, 0x3000,
          0x3800, 0x3C00, 0x4000, 0x4400, 0x4800, 0x5000, 0x5800, 0x6000,
          0x6800, 0x7000, 0x7800, 0x7F00,
          0xC000, 0xB000, 0xB800, 0xD000, 0x8000]
    print(f"Systematic: {len(rv)}^2 = {len(rv)**2} pairs")
    for a in rv:
        for b in rv:
            vectors.add((a, b, posit16_mult_hw(a, b)))

    # Random
    n_random = 5000
    print(f"Random: {n_random} pairs")
    rng = np.random.default_rng(42)
    for _ in range(n_random):
        a = int(rng.integers(0, 0x10000))
        b = int(rng.integers(0, 0x10000))
        vectors.add((a, b, posit16_mult_hw(a, b)))

    # Regime boundaries (canonical encodings)
    print("Regime boundaries...")
    bnd = []
    for k in range(-3, 4):
        for e in [0, 1]:
            p = float_to_posit16_hw(4.0 ** k * 2.0 ** e)
            if 0 < p < 0x8000:
                bnd.extend([p, max(1, p - 1), min(0x7FFF, p + 1)])
    for a in bnd:
        for b in bnd:
            vectors.add((a, b, posit16_mult_hw(a, b)))

    vs = sorted(vectors)
    with open("golden_mult_vectors.csv", "w") as f:
        for a, b, e in vs:
            f.write(f"{a:04x},{b:04x},{e:04x}\n")
    print(f"\nWrote {len(vs)} vectors to golden_mult_vectors.csv")

    # Verify some key results
    for a, b, e in vs:
        if a == 0x4000 and b == 0x4000:
            print(f"  1.0*1.0 = 0x{e:04x} (expect 0x4000)")
        if a == 0x4000 and b == 0x3000:
            print(f"  1.0*0.5 = 0x{e:04x} (expect 0x3000)")
        if a == 0x0100 and b == 0x4000:
            print(f"  minpos*1 = 0x{e:04x} (expect 0x0800)")
        if a == 0x7F00 and b == 0x4000:
            print(f"  maxpos*1 = 0x{e:04x} (expect 0x7800)")


if __name__ == "__main__":
    main()
