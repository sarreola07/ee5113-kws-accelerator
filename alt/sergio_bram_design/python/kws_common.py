"""Shared configuration, quantization helpers and the bit-exact integer
reference model for the KWS accelerator.

The function `int_forward` is the "golden model": the Verilog in rtl/ must
produce exactly the same predicted class for every test clip.  If you change
the arithmetic here, change rtl/fc_layer.v and rtl/relu.v the same way (and
vice versa).

Integer math (per clip):
    acc1[h] = b1[h] + sum_i x[i] * W1[h][i]            (32-bit signed)
    hid[h]  = clamp(acc1[h] >>> SHIFT1, 0, QMAX)        (ReLU + requantize)
    acc2[k] = b2[k] + sum_h hid[h] * W2[k][h]          (32-bit signed)
    class   = first index of max(acc2)                  (argmax, ties -> lowest)
"""
import json

import numpy as np

# ---------------------------------------------------------------- network ---
WORDS = ["yes", "no", "on", "off", "up", "down"]   # 4-6 keywords (proposal)
N_MFCC = 10          # MFCC coefficients per frame
N_FRAMES = 25        # frames per 1-second clip (after pooling)
N_IN = N_MFCC * N_FRAMES
N_HID = 32           # hidden neurons
N_OUT = len(WORDS)
ACC_W = 32           # accumulator width in hardware
N_MACS = N_IN * N_HID + N_HID * N_OUT   # multiply-accumulates per inference (8,192)

# Precisions exported for the hardware (name -> bits). INT8 vs INT4 is the
# proposal's comparison; INT6 is an extra data point between them.
PRECISIONS = {"int8": 8, "int6": 6, "int4": 4}

# --------------------------------------------------- audio features (MFCC) ---
# The same settings as torchaudio.transforms.MFCC(sample_rate=16000, n_mfcc=10,
# melkwargs={"n_fft": 400, "hop_length": 160, "n_mels": 40}); see kws_features.py.
SAMPLE_RATE = 16000
CLIP_SAMPLES = 16000        # 1 second
N_FFT = 400                 # 25 ms analysis window
HOP = 160                   # 10 ms hop -> 101 frames per clip
N_MELS = 40
F_MIN = 0.0
F_MAX = SAMPLE_RATE / 2
TOP_DB = 80.0
AMIN = 1e-10
N_STFT_FRAMES = 1 + CLIP_SAMPLES // HOP     # 101
assert N_IN == N_MFCC * N_FRAMES

# Stored next to cached features and trained models, so a mismatch is detected.
FEATURE_CFG = {"version": 1, "sr": SAMPLE_RATE, "clip": CLIP_SAMPLES, "n_fft": N_FFT,
               "hop": HOP, "n_mels": N_MELS, "n_mfcc": N_MFCC, "n_frames": N_FRAMES,
               "top_db": TOP_DB, "amin": AMIN, "words": WORDS}


def feature_cfg_json():
    return json.dumps(FEATURE_CFG, sort_keys=True)


def qmax(bits):
    return (1 << (bits - 1)) - 1


def quantize_sym(x, bits, scale=None):
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


def choose_shift(acc1, bits):
    """Smallest right-shift that maps the positive layer-1 range into [0, QMAX]."""
    peak = float(np.percentile(np.maximum(acc1, 0), 99.9))
    s = 0
    while (peak / (1 << s)) > qmax(bits):
        s += 1
    return s


def to_hex(v, bits):
    """Two's-complement hex string, width = ceil(bits/4) digits."""
    digits = (bits + 3) // 4
    return format(int(v) & ((1 << bits) - 1), f"0{digits}x")
