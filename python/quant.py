"""Integer (fixed-point) reference model. The Verilog accelerator must match it bit for bit.

Hardware data path for one inference. BW = bit width (8 or 4), QMAX = 2^(BW-1) - 1
(127 for INT8, 7 for INT4). All numbers are signed two's complement.

  1. Input    x[i]   : BW-bit,  x = clamp(round(feature / s_x), -QMAX, QMAX)  (done in software)
  2. Layer 1  acc[j] = b1[j] + sum_i W1[j][i] * x[i]                (ACC_W-bit accumulator)
  3. ReLU     r[j]   = max(acc[j], 0)
  4. Requant  h[j]   = min((r[j] + 2^(SHIFT-1)) >> SHIFT, QMAX)     (BW-bit, range 0..QMAX)
                       (if SHIFT == 0 then h[j] = min(r[j], QMAX))
  5. Layer 2  out[k] = b2[k] + sum_j W2[k][j] * h[j]
  6. Argmax   class  = k with the largest out[k]; on a tie the lowest k wins

Only a right shift is used to rescale between layers, so the hardware needs no extra
multiplier. ACC_W is chosen so that no partial sum can ever overflow.
"""
import numpy as np


def qmax(bits):
    return 2 ** (bits - 1) - 1


def round_half_up(x):
    """Same rounding as the hardware (add half, then floor / arithmetic shift)."""
    return np.floor(np.asarray(x, dtype=np.float64) + 0.5)


def signed_bits(max_abs):
    """Bits needed to hold any signed integer in [-max_abs, max_abs]."""
    return int(np.ceil(np.log2(int(max_abs) + 1))) + 1


# ---------------------------------------------------------------- scales
def choose_input_scale(x, bits, rng=None, n_samples=200_000):
    """Pick the input clipping range with the lowest quantization error (MSE)."""
    rng = rng or np.random.default_rng(0)
    x = np.ravel(x)
    if x.size > n_samples:
        x = rng.choice(x, n_samples, replace=False)
    x = x.astype(np.float64)
    q, top = qmax(bits), float(np.abs(x).max())
    best_err, best_scale = np.inf, top / q
    for clip in np.linspace(top / 50, top, 200):
        s = clip / q
        err = np.mean((np.clip(round_half_up(x / s), -q, q) * s - x) ** 2)
        if err < best_err:
            best_err, best_scale = err, s
    return float(best_scale)


def weight_scale(w, bits):
    """Symmetric per-layer scale: the largest weight maps to +/-QMAX."""
    return float(np.abs(w).max()) / qmax(bits)


def quantize(x, scale, bits):
    q = qmax(bits)
    return np.clip(round_half_up(np.asarray(x) / scale), -q, q).astype(np.int64)


def requant(r, shift, bits):
    """Step 4 above. r must be >= 0 (after ReLU)."""
    r = np.asarray(r, dtype=np.int64)
    if shift > 0:
        r = (r + (1 << (shift - 1))) >> shift
    return np.minimum(r, qmax(bits))


def choose_shift(acc, bits, max_shift=40):
    """Pick the requantization shift with the lowest MSE on calibration accumulators."""
    r = np.maximum(np.asarray(acc, dtype=np.int64), 0)
    best_err, best_shift = np.inf, 0
    for shift in range(max_shift + 1):
        err = np.mean((requant(r, shift, bits) * 2.0 ** shift - r) ** 2)
        if err < best_err:
            best_err, best_shift = err, shift
    return best_shift


# ---------------------------------------------------------------- model
def build_int_model(W1, b1, W2, b2, s_x, bits, shift=None, calib_x=None):
    """Convert float weights (W: [out, in]) to the integer model.

    shift=None picks SHIFT from calibration inputs calib_x (already quantized integers).
    """
    q = qmax(bits)
    s_w1, s_w2 = weight_scale(W1, bits), weight_scale(W2, bits)
    W1q = quantize(W1, s_w1, bits)
    b1q = round_half_up(np.asarray(b1) / (s_x * s_w1)).astype(np.int64)
    if shift is None:
        shift = choose_shift(np.asarray(calib_x, np.int64) @ W1q.T + b1q, bits)
    s_h = s_x * s_w1 * 2.0 ** shift
    W2q = quantize(W2, s_w2, bits)
    b2q = round_half_up(np.asarray(b2) / (s_h * s_w2)).astype(np.int64)

    n_hid, n_in = W1q.shape
    round_add = (1 << (shift - 1)) if shift > 0 else 0
    worst = max(n_in * q * q + np.abs(b1q).max() + round_add,
                n_hid * q * q + np.abs(b2q).max())
    return {
        "bits": int(bits), "acc_w": signed_bits(worst), "shift": int(shift),
        "s_x": float(s_x), "s_w1": s_w1, "s_w2": s_w2,
        "W1": W1q, "b1": b1q, "W2": W2q, "b2": b2q,
    }


def int_forward(m, x):
    """x: integer inputs (N, n_in). Returns (predicted class, hidden h, output logits)."""
    x = np.asarray(x, dtype=np.int64)
    acc1 = x @ m["W1"].T + m["b1"]
    h = requant(np.maximum(acc1, 0), m["shift"], m["bits"])
    out = h @ m["W2"].T + m["b2"]
    limit = 1 << (m["acc_w"] - 1)
    assert np.abs(acc1).max() < limit and np.abs(out).max() < limit, "accumulator overflow"
    return out.argmax(axis=1), h, out


def accuracy(m, features, labels):
    pred = int_forward(m, quantize(features, m["s_x"], m["bits"]))[0]
    return float(np.mean(pred == labels))


def save_int_model(path, m, words):
    np.savez(path, words=np.array(words), **m)


def load_int_model(path):
    d = np.load(path)
    m = {k: d[k] for k in ("W1", "b1", "W2", "b2")}
    m.update({k: int(d[k]) for k in ("bits", "acc_w", "shift")})
    m.update({k: float(d[k]) for k in ("s_x", "s_w1", "s_w2")})
    return m, [str(w) for w in d["words"]]
