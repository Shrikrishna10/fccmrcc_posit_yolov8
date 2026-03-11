#!/usr/bin/env python3
"""
gen_golden_vectors.py — Posit<16, es=1> utility module.

Provides:
    Posit16.encode(float)  -> int   (16-bit pattern)
    Posit16.decode(int)    -> float
    Posit16.ZERO, Posit16.NAR      (special bit patterns)
    POSIT_WIDTH = 16

The encode/decode logic is taken verbatim from gen_golden.py (pure Python,
zero external dependencies).
"""

import math

# ── Module-level constant ────────────────────────────────────────────────────
POSIT_WIDTH = 16

# ── Internal constants ───────────────────────────────────────────────────────
_NBITS      = 16
_ES         = 1
_REGIME_MAX = 3
_USEED      = 4.0
_MAXPOS_V   = float(_USEED ** _REGIME_MAX)
_MINPOS_V   = 1.0 / _MAXPOS_V
_NAR_BITS   = 0x8000
_ZERO_BITS  = 0x0000


def _clamp_int(x: int, lo: int, hi: int) -> int:
    return lo if x < lo else (hi if x > hi else x)


def _posit16_decode(bits) -> float:
    bits = int(bits) & 0xFFFF
    if bits == _ZERO_BITS:
        return 0.0
    if bits == _NAR_BITS:
        return float('nan')

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

    k: int = (run - 1) if rbit == 1 else (0 - run)
    k = _clamp_int(k, -_REGIME_MAX, _REGIME_MAX)

    consumed = run + (1 if run < 15 else 0)
    exp_start = 14 - consumed
    e = 0
    if exp_start >= 0:
        e = (body >> exp_start) & 1

    frac_start = exp_start - _ES
    frac_bits = max(0, frac_start + 1)
    f_val = 0.0
    if frac_bits > 0:
        frac_int = body & ((1 << frac_bits) - 1)
        f_val = frac_int / (1 << frac_bits)

    useed_pow: float = float(_USEED ** k)
    exp_pow: float = 2.0 ** e
    return sign * useed_pow * exp_pow * (1.0 + f_val)


def _posit16_encode(value: float) -> int:
    if value == 0.0:
        return _ZERO_BITS
    if math.isnan(value):
        return _NAR_BITS
    if math.isinf(value):
        return _NAR_BITS

    sign = 0 if value > 0 else 1
    value = abs(value)
    value = max(_MINPOS_V, min(_MAXPOS_V, value))

    log_u = math.log(value) / math.log(_USEED)
    k = int(math.floor(log_u))
    k = _clamp_int(k, -_REGIME_MAX, _REGIME_MAX)

    remaining = value / float(_USEED ** k)
    remaining = max(1.0, remaining)

    e = int(math.floor(math.log2(remaining)))
    e = _clamp_int(e, 0, (1 << _ES) - 1)

    remaining /= (2.0 ** e)
    remaining = max(1.0, remaining)
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


# ── Public class ─────────────────────────────────────────────────────────────
class Posit16:
    """Posit<16, es=1> encoder/decoder (pure Python)."""

    ZERO = _ZERO_BITS
    NAR  = _NAR_BITS

    @staticmethod
    def encode(value: float) -> int:
        """Encode a Python float to a 16-bit Posit bit-pattern."""
        return _posit16_encode(value)

    @staticmethod
    def decode(bits) -> float:
        """Decode a 16-bit Posit bit-pattern to a Python float."""
        return _posit16_decode(bits)
