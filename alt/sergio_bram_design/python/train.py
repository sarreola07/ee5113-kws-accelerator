#!/usr/bin/env python3
"""Train the keyword-spotting network in plain NumPy (no PyTorch needed).

    python python/train.py                   # download (first time), features, train
    python python/train.py --workers 16      # more CPU processes for feature extraction
    python python/train.py --tar FILE.tar.gz # use a local copy of the dataset archive

Pipeline: 1 s of audio -> 250 MFCC numbers (kws_features.py) -> standardize ->
FC 250->32 -> ReLU -> FC 32->6 -> softmax over the 6 words.

Training: mini-batch Adam on the cross-entropy loss with a small L2 weight
penalty. After every epoch the model is scored on the validation split. The
epoch with the best validation accuracy is kept (early stopping), and the test
split is scored once, at the very end. docs/TRAINING.md explains each step.

Outputs (git-ignored; you can always re-create them):
    python/data/speech_commands_v0.02/   the 6 words and the split lists (~0.75 GB)
    python/data/features.npz             cached features (rebuilt if settings change)
    python/checkpoints/model.npz         float weights w1, b1, w2, b2 plus mu, sd, meta
Next step: python python/quantize_export.py
"""
import argparse
import json
import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kws_data  # noqa: E402
from kws_common import N_HID, N_IN, N_OUT, WORDS, feature_cfg_json  # noqa: E402
from kws_features import features_from_files  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "python", "data")
FEATURES = os.path.join(DATA, "features.npz")
CKPT = os.path.join(ROOT, "python", "checkpoints", "model.npz")


# ------------------------------------------------------------------ features ---
def build_features(data_dir, workers=1, max_per_word=0, seed=0):
    """Compute MFCC features for every clip and save them, standardized, to features.npz."""
    splits = kws_data.split_files(data_dir)
    rng = np.random.default_rng(seed)
    arrays = {}
    for name in ("train", "val", "test"):
        items = splits[name]
        if max_per_word:                     # quick experiments: cap each word
            keep = []
            for label in range(N_OUT):
                idx = [i for i, (_, lab) in enumerate(items) if lab == label]
                keep += sorted(rng.permutation(idx)[:max_per_word].tolist())
            items = [items[i] for i in sorted(keep)]
        paths = [p for p, _ in items]
        arrays["x_" + name] = features_from_files(paths, workers, name)
        arrays["y_" + name] = np.array([lab for _, lab in items], dtype=np.int64)
        arrays["files_" + name] = np.array([os.path.relpath(p, data_dir) for p in paths])
    # Standardize every feature with the TRAINING mean and spread (never peek at val/test).
    mu = arrays["x_train"].mean(axis=0)
    sd = arrays["x_train"].std(axis=0) + 1e-6
    for name in ("train", "val", "test"):
        arrays["x_" + name] = ((arrays["x_" + name] - mu) / sd).astype(np.float32)
    os.makedirs(os.path.dirname(FEATURES), exist_ok=True)
    np.savez(FEATURES, mu=mu, sd=sd, cfg=feature_cfg_json(), max_per_word=max_per_word, **arrays)
    return np.load(FEATURES)


def load_features(data_dir, workers, max_per_word, rebuild):
    if not rebuild and os.path.exists(FEATURES):
        f = np.load(FEATURES)
        if str(f["cfg"]) == feature_cfg_json() and int(f["max_per_word"]) == max_per_word:
            print(f"using cached features {os.path.relpath(FEATURES, ROOT)}")
            return f
        print("feature settings changed: rebuilding features")
    return build_features(data_dir, workers, max_per_word)


# --------------------------------------------------------------------- model ---
def init_params(rng, n_in=N_IN, n_hid=N_HID, n_out=N_OUT, dtype=np.float32):
    """He initialization: weights ~ N(0, 2/fan_in), biases 0."""
    return {"w1": rng.normal(0.0, np.sqrt(2.0 / n_in), (n_hid, n_in)).astype(dtype),
            "b1": np.zeros(n_hid, dtype),
            "w2": rng.normal(0.0, np.sqrt(2.0 / n_hid), (n_out, n_hid)).astype(dtype),
            "b2": np.zeros(n_out, dtype)}


def forward(p, x):
    z1 = x @ p["w1"].T + p["b1"]          # layer 1: (batch, 32)
    h = np.maximum(z1, 0)                  # ReLU
    z2 = h @ p["w2"].T + p["b2"]          # layer 2: (batch, 6) scores ("logits")
    return z1, h, z2


def log_softmax(z):
    z = z - z.max(axis=1, keepdims=True)  # subtract the max for numerical safety
    return z - np.log(np.exp(z).sum(axis=1, keepdims=True))


def loss_and_grads(p, x, y, wd):
    """Mean cross-entropy + (wd/2)*||W||^2, and its gradient (backpropagation)."""
    n = len(y)
    z1, h, z2 = forward(p, x)
    logp = log_softmax(z2)
    loss = -logp[np.arange(n), y].mean() + 0.5 * wd * ((p["w1"] ** 2).sum() + (p["w2"] ** 2).sum())
    dz2 = np.exp(logp)                     # softmax probabilities ...
    dz2[np.arange(n), y] -= 1.0            # ... minus the one-hot target
    dz2 /= n
    g = {"w2": dz2.T @ h + wd * p["w2"], "b2": dz2.sum(axis=0)}
    dz1 = (dz2 @ p["w2"]) * (z1 > 0)      # back through ReLU
    g["w1"] = dz1.T @ x + wd * p["w1"]
    g["b1"] = dz1.sum(axis=0)
    return float(loss), g


def adam_step(p, g, state, lr, t, b1=0.9, b2=0.999, eps=1e-8):
    """One Adam update: moving averages of the gradient and its square."""
    for k in p:
        m, v = state.setdefault(k, (np.zeros_like(p[k]), np.zeros_like(p[k])))
        m = b1 * m + (1 - b1) * g[k]
        v = b2 * v + (1 - b2) * g[k] ** 2
        state[k] = (m, v)
        p[k] -= lr * (m / (1 - b1 ** t)) / (np.sqrt(v / (1 - b2 ** t)) + eps)


def evaluate(p, x, y):
    """(accuracy, mean cross-entropy) of the model on clips x with labels y."""
    if not len(y):
        return float("nan"), float("nan")
    z2 = forward(p, x)[2]
    logp = log_softmax(z2)
    return float(np.mean(np.argmax(z2, axis=1) == y)), float(-logp[np.arange(len(y)), y].mean())


def train(x_tr, y_tr, x_val, y_val, epochs=100, lr=1e-3, batch=128, wd=1e-4,
          patience=10, seed=0, verbose=True):
    """Mini-batch Adam with early stopping on validation accuracy. Returns (params, history)."""
    rng = np.random.default_rng(seed)
    p = init_params(rng, x_tr.shape[1], N_HID, int(max(y_tr.max(), y_val.max())) + 1)
    best = (-1.0, np.inf, 0, {k: v.copy() for k, v in p.items()})
    state, t, history = {}, 0, []
    for epoch in range(1, epochs + 1):
        order = rng.permutation(len(y_tr))           # new shuffle every epoch
        losses = []
        for i in range(0, len(order), batch):
            idx = order[i:i + batch]
            loss, g = loss_and_grads(p, x_tr[idx], y_tr[idx], wd)
            t += 1
            adam_step(p, g, state, lr, t)
            losses.append(loss)
        tr_acc, _ = evaluate(p, x_tr, y_tr)
        val_acc, val_loss = evaluate(p, x_val, y_val)
        improved = val_acc > best[0] or (val_acc == best[0] and val_loss < best[1])
        if improved:
            best = (val_acc, val_loss, epoch, {k: v.copy() for k, v in p.items()})
        history.append({"epoch": epoch, "loss": float(np.mean(losses)), "train_acc": tr_acc,
                        "val_acc": val_acc, "val_loss": val_loss})
        if verbose:
            print(f"epoch {epoch:3d}  loss {np.mean(losses):.4f}  train acc {tr_acc:.4f}  "
                  f"val acc {val_acc:.4f}{'  *best' if improved else ''}", flush=True)
        if epoch - best[2] >= patience:
            if verbose:
                print(f"no improvement for {patience} epochs: stopping, keeping epoch {best[2]}")
            break
    return best[3], {"history": history, "best_epoch": best[2], "best_val_acc": best[0]}


# ---------------------------------------------------------------------- main ---
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--epochs", type=int, default=100, help="maximum epochs")
    ap.add_argument("--lr", type=float, default=1e-3, help="Adam learning rate")
    ap.add_argument("--batch", type=int, default=128, help="mini-batch size")
    ap.add_argument("--weight-decay", type=float, default=1e-4, help="L2 penalty on weights")
    ap.add_argument("--patience", type=int, default=10, help="early-stopping patience (epochs)")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--workers", type=int, default=min(8, os.cpu_count() or 1),
                    help="processes for feature extraction")
    ap.add_argument("--max-per-word", type=int, default=0, help="cap clips per word (quick runs)")
    ap.add_argument("--data-dir", default=kws_data.DEFAULT_DEST)
    ap.add_argument("--tar", help="local copy of speech_commands_v0.02.tar.gz")
    ap.add_argument("--rebuild-features", action="store_true")
    ap.add_argument("--download-only", action="store_true")
    a = ap.parse_args()

    t0 = time.time()
    info = kws_data.download(a.data_dir, tar_path=a.tar)
    if a.download_only:
        return
    f = load_features(a.data_dir, a.workers, a.max_per_word, a.rebuild_features)
    print("clips: " + ", ".join(f"{s} {len(f['y_' + s])}" for s in ("train", "val", "test"))
          + f"  (features ready after {time.time() - t0:.0f} s)")

    p, hist = train(f["x_train"], f["y_train"], f["x_val"], f["y_val"], a.epochs, a.lr,
                    a.batch, a.weight_decay, a.patience, a.seed)
    test_acc, _ = evaluate(p, f["x_test"], f["y_test"])
    val_acc, _ = evaluate(p, f["x_val"], f["y_val"])
    meta = {"feature_cfg": feature_cfg_json(), "words": WORDS, "seed": a.seed, "epochs_max": a.epochs,
            "lr": a.lr, "batch": a.batch, "weight_decay": a.weight_decay, "patience": a.patience,
            "best_epoch": hist["best_epoch"], "val_acc": val_acc, "test_acc": test_acc,
            "max_per_word": a.max_per_word, "dataset_md5": info.get("md5"),
            "n_train": int(len(f["y_train"])), "n_val": int(len(f["y_val"])), "n_test": int(len(f["y_test"])),
            "history": hist["history"]}
    os.makedirs(os.path.dirname(CKPT), exist_ok=True)
    np.savez(CKPT, mu=f["mu"], sd=f["sd"], meta=json.dumps(meta), **p)
    print(f"\nbest epoch {hist['best_epoch']}: validation accuracy {val_acc:.4f}, "
          f"test accuracy {test_acc:.4f} (float model)")
    print(f"saved {os.path.relpath(CKPT, ROOT)} after {time.time() - t0:.0f} s\n"
          f"next: python python/quantize_export.py")


if __name__ == "__main__":
    main()
