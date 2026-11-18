#!/usr/bin/env python3
"""Train the small keyword-spotting network (float) on Google Speech Commands.

Pipeline:  1 s audio @16 kHz -> MFCC (N_MFCC x ~101 frames) -> average-pool to
N_FRAMES frames -> flatten (N_IN) -> FC(N_HID) -> ReLU -> FC(N_OUT).

Outputs (both git-ignored, regenerate any time):
    python/data/features.npz        cached MFCC features + labels (train/test)
    python/checkpoints/model.npz    float weights (w1, b1, w2, b2)

Then run:  python python/quantize_export.py

Run this on a laptop (Mac/Windows) - it needs PyTorch + torchaudio and
downloads ~2.3 GB the first time.  The crosby3 server is not needed.
"""
import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kws_common import N_FRAMES, N_HID, N_IN, N_MFCC, N_OUT, WORDS  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "python", "data")
CKPT = os.path.join(ROOT, "python", "checkpoints")


def build_features(max_per_word):
    import torch
    import torchaudio

    os.makedirs(DATA, exist_ok=True)
    mfcc = torchaudio.transforms.MFCC(sample_rate=16000, n_mfcc=N_MFCC,
                                      melkwargs={"n_fft": 400, "hop_length": 160, "n_mels": 40})
    out = {}
    for split in ("training", "testing"):
        ds = torchaudio.datasets.SPEECHCOMMANDS(DATA, download=True, subset=split)
        xs, ys, count = [], [], {w: 0 for w in WORDS}
        for i in range(len(ds)):
            path = ds._walker[i]                       # avoid loading audio for unused words
            word = os.path.basename(os.path.dirname(path))
            if word not in count or count[word] >= max_per_word:
                continue
            wav, sr, *_ = ds[i]
            wav = torch.nn.functional.pad(wav, (0, 16000 - wav.shape[1]))[:, :16000]
            f = mfcc(wav)[0]                           # (N_MFCC, 101)
            f = torch.nn.functional.adaptive_avg_pool1d(f.unsqueeze(0), N_FRAMES)[0]
            xs.append(f.T.reshape(-1).numpy())         # frame-major flatten -> N_IN
            ys.append(WORDS.index(word))
            count[word] += 1
        out[split] = (np.stack(xs).astype(np.float32), np.array(ys))
        print(f"{split}: {len(ys)} clips {count}")
    xtr, ytr = out["training"]
    xte, yte = out["testing"]
    mu, sd = xtr.mean(0), xtr.std(0) + 1e-6           # normalize features
    np.savez(os.path.join(DATA, "features.npz"), x_train=(xtr - mu) / sd, y_train=ytr,
             x_test=(xte - mu) / sd, y_test=yte, mu=mu, sd=sd)


def train(epochs, lr):
    import torch
    f = np.load(os.path.join(DATA, "features.npz"))
    xtr, ytr = torch.tensor(f["x_train"]), torch.tensor(f["y_train"])
    xte, yte = torch.tensor(f["x_test"]), torch.tensor(f["y_test"])
    assert xtr.shape[1] == N_IN
    torch.manual_seed(0)
    net = torch.nn.Sequential(torch.nn.Linear(N_IN, N_HID), torch.nn.ReLU(),
                              torch.nn.Linear(N_HID, N_OUT))
    opt = torch.optim.Adam(net.parameters(), lr=lr, weight_decay=1e-4)
    for ep in range(epochs):
        net.train()
        perm = torch.randperm(len(xtr))
        for i in range(0, len(xtr), 128):
            idx = perm[i:i + 128]
            loss = torch.nn.functional.cross_entropy(net(xtr[idx]), ytr[idx])
            opt.zero_grad()
            loss.backward()
            opt.step()
        net.eval()
        with torch.no_grad():
            acc = (net(xte).argmax(1) == yte).float().mean().item()
        print(f"epoch {ep + 1:3d}  loss {loss.item():.3f}  test acc {acc:.3f}")
    os.makedirs(CKPT, exist_ok=True)
    np.savez(os.path.join(CKPT, "model.npz"),
             w1=net[0].weight.detach().numpy(), b1=net[0].bias.detach().numpy(),
             w2=net[2].weight.detach().numpy(), b2=net[2].bias.detach().numpy())
    print("saved python/checkpoints/model.npz")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--epochs", type=int, default=40)
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--max-per-word", type=int, default=3000)
    ap.add_argument("--rebuild-features", action="store_true")
    a = ap.parse_args()
    if a.rebuild_features or not os.path.exists(os.path.join(DATA, "features.npz")):
        build_features(a.max_per_word)
    train(a.epochs, a.lr)
