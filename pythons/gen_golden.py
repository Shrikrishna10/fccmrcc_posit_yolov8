#!/usr/bin/env python3
"""
gen_golden.py  —  Pure Python, zero dependencies.
Posit<16, es=1> encode/decode verified correct. Run before simulation.

OUTPUTS -> ../golden/
    mitchell_corr_lut.hex
    mitchell_mult_vectors.csv
    approx_adder_vectors.csv
    pe_dot_product_vectors.csv
    reduction_tree_vectors.csv
    array_dot_product_vectors.csv

USAGE:  python scripts/gen_golden.py   (from project root)
"""

import os, math, random

random.seed(0xDEADBEEF)

ROOT   = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTDIR = os.path.join(ROOT, "golden")
os.makedirs(OUTDIR, exist_ok=True)

NBITS      = 16
ES         = 1
REGIME_MAX = 3
USEED      = 4.0
MAXPOS_V   = float(USEED ** REGIME_MAX)
MINPOS_V   = 1.0 / MAXPOS_V
NAR_BITS   = 0x8000
ZERO_BITS  = 0x0000

def _clamp_int(x: int, lo: int, hi: int) -> int:
    return lo if x < lo else (hi if x > hi else x)

def _clamp_float(x: float, lo: float, hi: float) -> float:
    return lo if x < lo else (hi if x > hi else x)

def posit16_decode(bits) -> float:
    bits = int(bits) & 0xFFFF
    if bits == ZERO_BITS: return 0.0
    if bits == NAR_BITS:  return float('inf')
    sign: float = 1.0 if (bits >> 15) == 0 else -1.0
    if sign == -1.0:
        bits = ((~bits) + 1) & 0xFFFF
    body: int = bits & 0x7FFF
    rbit: int = (body >> 14) & 1
    run: int = 0
    for i in range(14, -1, -1):
        if ((body >> i) & 1) == rbit:
            run += 1
        else:
            break
    k: int   = (run - 1) if rbit == 1 else (0 - run)
    k        = _clamp_int(k, -REGIME_MAX, REGIME_MAX)
    consumed = run + (1 if run < 15 else 0)
    exp_start = 14 - consumed
    e = 0
    if exp_start >= 0:
        e = (body >> exp_start) & 1
    frac_start = exp_start - ES
    frac_bits  = max(0, frac_start + 1)
    f_val = 0.0
    if frac_bits > 0:
        frac_int = body & ((1 << frac_bits) - 1)
        f_val = frac_int / (1 << frac_bits)
    useed_pow: float = float(USEED ** k)
    exp_pow: float = 2.0 ** e
    return sign * useed_pow * exp_pow * (1.0 + f_val)

def posit16_encode(value: float) -> int:
    if value == 0.0:             return ZERO_BITS
    if math.isnan(value):        return NAR_BITS
    if math.isinf(value):        return NAR_BITS
    sign  = 0 if value > 0 else 1
    value = abs(value)
    value = max(MINPOS_V, min(MAXPOS_V, value))
    log_u = math.log(value) / math.log(USEED)
    k = int(math.floor(log_u))
    k = _clamp_int(k, -REGIME_MAX, REGIME_MAX)
    remaining = value / float(USEED ** k)
    remaining = max(1.0, remaining)
    e = int(math.floor(math.log2(remaining)))
    e = _clamp_int(e, 0, (1 << ES) - 1)
    remaining /= (2.0 ** e)
    remaining  = max(1.0, remaining)
    frac_float = remaining - 1.0
    parts: list[int] = []
    pos: int = 14
    if k >= 0:
        for _ in range(k + 1):
            if pos >= 0:
                parts.append(1 << pos)
            pos = pos - 1
        if pos >= 0:
            pos = pos - 1
    else:
        for _ in range(-k):
            pos = pos - 1
        if pos >= 0:
            parts.append(1 << pos)
        pos = pos - 1
    if pos >= 0:
        parts.append(e << pos)
        pos = pos - 1
    frac_bits: int = pos + 1
    if frac_bits > 0:
        frac_int: int = int(round(frac_float * (1 << frac_bits)))
        frac_int = min(frac_int, (1 << frac_bits) - 1)
        parts.append(frac_int)
    body: int = sum(parts) & 0x7FFF
    if sign == 1:
        return ((~body) + 1) & 0xFFFF
    return body

def p16_mul(a, b):
    if a == ZERO_BITS or b == ZERO_BITS: return ZERO_BITS
    if a == NAR_BITS  or b == NAR_BITS:  return NAR_BITS
    return posit16_encode(posit16_decode(a) * posit16_decode(b))

def p16_add(a, b):
    if a == NAR_BITS  or b == NAR_BITS:  return NAR_BITS
    if a == ZERO_BITS: return b
    if b == ZERO_BITS: return a
    return posit16_encode(posit16_decode(a) + posit16_decode(b))

def p16_neg(bits: int) -> int:
    if bits in (ZERO_BITS, NAR_BITS): return bits
    return ((~int(bits)) + 1) & 0xFFFF

def rand_pos():
    return random.randint(0x0001, 0x7FFE)

def signed32(bits):
    bits &= 0xFFFF
    return bits - 0x10000 if bits & 0x8000 else bits

def h(bits): return f"{bits & 0xFFFF:04x}"

# ── Sanity check ─────────────────────────────────────────────────────────────
KNOWN = [
    (0x0000,0.0),(0x4000,1.0),(0x5000,2.0),(0x6000,4.0),
    (0x7000,16.0),(0x7800,64.0),(0x3000,0.5),(0x2000,0.25),(0x1800,0.125),
]
print("=== Decode sanity ===")
all_ok = True
for bits, expected in KNOWN:
    got = posit16_decode(bits)
    ok  = (got == 0.0 and expected == 0.0) or (expected != 0.0 and abs(got/expected-1) < 1e-6)
    print(f"  0x{bits:04X}  got={got:<10.4f}  exp={expected:<10.4f}  {'OK' if ok else 'FAIL <<<'}")
    if not ok: all_ok = False
if not all_ok:
    raise SystemExit("DECODE SANITY FAILED")

print("=== Encode round-trip ===")
for v in [1.0, 2.0, 4.0, 16.0, 64.0, 0.5, 0.25, 0.125]:
    bits = posit16_encode(v)
    back = posit16_decode(bits)
    ok   = abs(back/v - 1) < 1e-6
    print(f"  {v:<8.4f}  -> 0x{bits:04X}  -> {back:<10.4f}  {'OK' if ok else 'FAIL <<<'}")
    if not ok: all_ok = False
if not all_ok:
    raise SystemExit("ENCODE ROUND-TRIP FAILED")
print("All sanity checks passed.\n")

# ── 1. Mitchell correction LUT ────────────────────────────────────────────────
LUT_IDX = 5; FRAC_W = 11
lut_path = os.path.join(OUTDIR, "mitchell_corr_lut.hex")
with open(lut_path,"w") as f:
    for idx in range(1 << (2*LUT_IDX)):
        fa_t=(idx>>LUT_IDX)&0x1F; fb_t=idx&0x1F
        corr=min(int((fa_t/(1<<LUT_IDX))*(fb_t/(1<<LUT_IDX))*(1<<FRAC_W)),(1<<FRAC_W)-1)
        f.write(f"{corr:03x}\n")
print(f"LUT:      {os.path.basename(lut_path)}")

# ── 2. Multiply vectors ───────────────────────────────────────────────────────
with open(os.path.join(OUTDIR,"mitchell_mult_vectors.csv"),"w") as f:
    f.write("a_hex,b_hex,expected_hex,fa,fb,fexpected\n")
    def mrow(a,b):
        e=p16_mul(a,b)
        fa_s="NaR" if a==NAR_BITS else f"{posit16_decode(a):.6f}"
        fb_s="NaR" if b==NAR_BITS else f"{posit16_decode(b):.6f}"
        fe_s="NaR" if e==NAR_BITS else f"{posit16_decode(e):.6f}"
        f.write(f"{h(a)},{h(b)},{h(e)},{fa_s},{fb_s},{fe_s}\n")
    for a,b in [(0x4000,0x4000),(0x5000,0x5000),(0x4000,0x5000),(0x6000,0x4000),
                (0x3000,0x5000),(0x3000,0x3000),(p16_neg(0x4000),0x4000),
                (p16_neg(0x4000),p16_neg(0x4000)),(ZERO_BITS,0x4000),
                (0x4000,ZERO_BITS),(NAR_BITS,0x4000),(0x4000,NAR_BITS)]:
        mrow(a,b)
    for _ in range(2000): mrow(rand_pos(),rand_pos())
print(f"Mult:     mitchell_mult_vectors.csv  (2012 rows)")

# ── 3. Adder vectors ──────────────────────────────────────────────────────────
with open(os.path.join(OUTDIR,"approx_adder_vectors.csv"),"w") as f:
    f.write("a_hex,b_hex,expected_hex,fa,fb,fexpected\n")
    def arow(a,b):
        e=p16_add(a,b)
        fa_s="NaR" if a==NAR_BITS else f"{posit16_decode(a):.6f}"
        fb_s="NaR" if b==NAR_BITS else f"{posit16_decode(b):.6f}"
        fe_s="NaR" if e==NAR_BITS else f"{posit16_decode(e):.6f}"
        f.write(f"{h(a)},{h(b)},{h(e)},{fa_s},{fb_s},{fe_s}\n")
    for a,b in [(0x4000,0x4000),(0x5000,0x4000),(0x3000,0x4000),(0x5000,0x5000),
                (0x4000,p16_neg(0x4000)),(0x4000,p16_neg(0x3000)),
                (ZERO_BITS,0x4000),(0x4000,ZERO_BITS),(NAR_BITS,0x4000),(0x4000,NAR_BITS)]:
        arow(a,b)
    for bits in [0x4000,0x5000,0x3000,0x6000,0x2000]: arow(bits,p16_neg(bits))
    for _ in range(2000): arow(rand_pos(),rand_pos())
print(f"Adder:    approx_adder_vectors.csv  (2015 rows)")

# ── 4. PE dot product vectors ─────────────────────────────────────────────────
def pe_ref(w, acts):
    acc=0
    for a in acts: acc+=signed32(p16_mul(w,a))
    return max(-2**31,min(2**31-1,acc))

with open(os.path.join(OUTDIR,"pe_dot_product_vectors.csv"),"w") as f:
    f.write("weight_hex,a0,a1,a2,a3,a4,a5,a6,a7,expected_acc\n")
    for w,acts in [(0x4000,[0x4000]*8),(0x5000,[0x4000]*8),(0x6000,[0x4000]*8),
                   (0x4000,[0x5000]*8),(0x4000,[ZERO_BITS]*8),
                   (0x4000,[0x5000,0x3000]*4),(p16_neg(0x4000),[0x4000]*8)]:
        f.write(f"{h(w)},"+",".join(h(a) for a in acts)+f",{pe_ref(w,acts)}\n")
    for _ in range(200):
        w=rand_pos(); acts=[rand_pos() for _ in range(8)]
        f.write(f"{h(w)},"+",".join(h(a) for a in acts)+f",{pe_ref(w,acts)}\n")
print(f"PE:       pe_dot_product_vectors.csv  (207 rows)")

# ── 5. Reduction tree vectors ─────────────────────────────────────────────────
def rt_ref(accs):
    return posit16_encode(float(max(-2**31,min(2**31-1,sum(accs)))))

with open(os.path.join(OUTDIR,"reduction_tree_vectors.csv"),"w") as f:
    f.write("acc0,acc1,acc2,acc3,expected_hex,fexpected\n")
    for accs in [[0,0,0,0],[0x4000,0,0,0],[0x4000]*4,[100,200,300,400],
                 [-100,100,-200,200],[32767,0,0,0],[16384,16384,0,0],[-1,-1,-1,-1]]:
        e=rt_ref(accs)
        f.write(",".join(str(a) for a in accs)+f",{h(e)},{posit16_decode(e):.6f}\n")
    for _ in range(500):
        accs=[random.randint(-32768,32767) for _ in range(4)]
        e=rt_ref(accs)
        f.write(",".join(str(a) for a in accs)+f",{h(e)},{posit16_decode(e):.6f}\n")
print(f"RedTree:  reduction_tree_vectors.csv  (508 rows)")

# ── 6. Array dot product vectors ──────────────────────────────────────────────
N_PES=4; N_ACTS=16
def array_ref(weights,acts):
    pe_accs=[0]*N_PES
    for p in range(N_ACTS//N_PES):
        for i in range(N_PES):
            pe_accs[i]+=signed32(p16_mul(weights[i],acts[p*N_PES+i]))
    return posit16_encode(float(max(-2**31,min(2**31-1,sum(pe_accs)))))

with open(os.path.join(OUTDIR,"array_dot_product_vectors.csv"),"w") as f:
    f.write("w0,w1,w2,w3,"+",".join(f"a{i}" for i in range(16))+",expected_hex,fexpected\n")
    for weights,acts in [([0x4000]*4,[0x4000]*16),([0x5000]*4,[0x4000]*16),
                          ([0x4000]*4,[0x5000]*16),([0x4000]*4,[0x0000]*16),
                          ([0x6000]*4,[0x4000]*16)]:
        e=array_ref(weights,acts)
        f.write(",".join(h(x) for x in weights)+","+",".join(h(x) for x in acts)+
                f",{h(e)},{posit16_decode(e):.4f}\n")
    for _ in range(100):
        weights=[rand_pos() for _ in range(N_PES)]; acts=[rand_pos() for _ in range(N_ACTS)]
        e=array_ref(weights,acts)
        f.write(",".join(h(x) for x in weights)+","+",".join(h(x) for x in acts)+
                f",{h(e)},{posit16_decode(e):.4f}\n")
print(f"Array:    array_dot_product_vectors.csv  (105 rows)")

print("\n=== Key hardcoded values (put these in testbench comments) ===")
print(f"  0x4000 = {posit16_decode(0x4000):.1f}   (1.0)")
print(f"  0x5000 = {posit16_decode(0x5000):.1f}   (2.0)")
print(f"  0x6000 = {posit16_decode(0x6000):.1f}   (4.0)")
print(f"  0x3000 = {posit16_decode(0x3000):.1f}   (0.5)")
print(f"  1.0*1.0 -> 0x{p16_mul(0x4000,0x4000):04X} ({posit16_decode(p16_mul(0x4000,0x4000)):.1f})")
print(f"  2.0*2.0 -> 0x{p16_mul(0x5000,0x5000):04X} ({posit16_decode(p16_mul(0x5000,0x5000)):.1f})")
print(f"  1.0+1.0 -> 0x{p16_add(0x4000,0x4000):04X} ({posit16_decode(p16_add(0x4000,0x4000)):.1f})")
print(f"  PE w=1.0 8x acts=1.0 acc={pe_ref(0x4000,[0x4000]*8)}")
print(f"  PE w=2.0 8x acts=1.0 acc={pe_ref(0x5000,[0x4000]*8)}")
e_arr=array_ref([0x4000]*4,[0x4000]*16)
print(f"  Array 4xw=1.0 16xa=1.0 -> 0x{e_arr:04X} ({posit16_decode(e_arr):.1f})")
print("\nDone. All golden files written to golden/")
