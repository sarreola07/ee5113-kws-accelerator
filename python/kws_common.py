"""Shared configuration, quantization helpers and the bit-exact integer
reference model for the KWS accelerator.

The function `int_forward` is the "golden model": the Verilog in rtl/ must
produce exactly the same predicted class for every test clip.  If you change
the arithmetic here, change rtl/fc_layer.v the same way (and vice versa).

Integer math (per clip):
    acc1[h] = b1[h] + sum_i x[i] * W1[h][i]            (32-bit signed)
    hid[h]  = clamp(acc1[h] >>> SHIFT1, 0, QMAX)        (ReLU + requantize)
    acc2[k] = b2[k] + sum_h hid[h] * W2[k][h]          (32-bit signed)
    class   = first index of max(acc2)                  (argmax, ties -> lowest)
"""
import numpy as np

# ---------------------------------------------------------------- config ---
WORDS = ["yes", "no", "on", "off", "up", "down"]   # 4-6 keywords (proposal)
N_MFCC = 10          # MFCC coefficients per frame
N_FRAMES = 25        # frames per 1-second clip (after pooling)
N_IN = N_MFCC * N_FRAMES
N_HID = 32           # hidden neurons
N_OUT = len(WORDS)
ACC_W = 32           # accumulator width in hardware

PRECISIONS = {"int8": 8, "int4": 4}


def qmax(bits: int) -> int:
    return (1 << (bits - 1)) - 1


def quantize_sym(x: np.ndarray, bits: int, scale: float | None = None):
    """Symmetric per-tensor quantization to [-qmax, qmax]. Returns (q, scale)."""
    q = qmax(bits)
    if scale is None:
        m = float(np.max(np.abs(x)))
        scale = m / q if m > 0 else 1.0
    xq = np.clip(np.round(x / scale), -q, q).astype(np.int64)
    return xq, scale


def int_forward(x, w1, b1, w2, b2, shift1, bits):
    """Bit-exact integer inference. x: (N, N_IN) int. Returns (classes, logits, hidden)."""
    x = np.asarray(x, dtype=np.int64)
    acc1 = x @ w1.T.astype(np.int64) + b1.astype(np.int64)
    hid = np.clip(acc1 >> shift1, 0, qmax(bits))           # >> on int64 = arithmetic
    acc2 = hid @ w2.T.astype(np.int64) + b2.astype(np.int64)
    cls = np.argmax(acc2, axis=1)                            # numpy: first max wins
    _check_acc_range(acc1, acc2)
    return cls, acc2, hid


def _check_acc_range(*accs):
    lim = 1 << (ACC_W - 1)
    for a in accs:
        if a.size and (a.max() >= lim or a.min() < -lim):
            raise OverflowError("accumulator exceeds ACC_W bits; widen ACC_W in RTL+Python")


def choose_shift(acc1: np.ndarray, bits: int) -> int:
    """Smallest right-shift that maps the positive layer-1 range into [0, QMAX]."""
    peak = float(np.percentile(np.maximum(acc1, 0), 99.9))
    s = 0
    while (peak / (1 << s)) > qmax(bits):
        s += 1
    return s


def to_hex(v: int, bits: int) -> str:
    """Two's-complement hex string, width = ceil(bits/4) digits."""
    digits = (bits + 3) // 4
    return format(int(v) & ((1 << bits) - 1), f"0{digits}x")
