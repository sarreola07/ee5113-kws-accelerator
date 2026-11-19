"""Quick check that everything works (about 1 minute).

    python python/quick_test.py

Uses only a small sample of the downloaded clips (200 per word for training, 50 per word
for testing), trains for a few epochs, and builds the INT8 / INT4 integer models with the
same code as the full run. It does not change python/data/features.npz, results/python/, weights/ or
figures/. Accuracy is lower than the full run because it sees about 15x less data.
"""
import sys
import time

import numpy as np
import torch

import config as C
import prepare_data as P
import quant as Q
from train import FloatMLP, QATMLP, predict, train_epoch, weights_numpy

N_TRAIN, N_TEST = 200, 50       # clips per word
EPOCHS, QAT_EPOCHS = 30, 5


def sample(items, n, rng):
    picked = []
    for label in range(len(C.WORDS)):
        mine = [item for item in items if item[1] == label]
        idx = rng.choice(len(mine), min(n, len(mine)), replace=False)
        picked += [mine[i] for i in sorted(idx)]
    return picked


def main():
    start = time.time()
    if not (C.SPEECH_DIR / "testing_list.txt").exists():
        print("No audio found. Run  python python/prepare_data.py  once first (it downloads the dataset).")
        return 1
    torch.manual_seed(C.SEED)
    rng = np.random.default_rng(C.SEED)

    print(f"Quick test: {N_TRAIN} training + {N_TEST} test clips per word, words = {C.WORDS}")
    splits = P.split_files(C.WORDS)
    Xtr, ytr = P.features_for(sample(splits["train"], N_TRAIN, rng), "train")
    Xte, yte = P.features_for(sample(splits["test"], N_TEST, rng), "test")
    mean, std = Xtr.mean(axis=0), Xtr.std(axis=0) + 1e-6
    Xtr, Xte = ((Xtr - mean) / std).astype(np.float32), ((Xte - mean) / std).astype(np.float32)
    tXtr, tytr, tXte = torch.from_numpy(Xtr), torch.from_numpy(ytr), torch.from_numpy(Xte)

    print(f"Training FP32 model ({EPOCHS} epochs)...")
    model = FloatMLP(C.N_INPUTS, C.N_HIDDEN, len(C.WORDS), C.DROPOUT)
    opt = torch.optim.Adam(model.parameters(), lr=C.FLOAT_LR, weight_decay=C.WEIGHT_DECAY)
    for _ in range(EPOCHS):
        train_epoch(model, tXtr, tytr, opt, C.BATCH_SIZE)
    results = [("FP32", float(np.mean(predict(model, tXte) == yte)), "")]

    for bits in C.BIT_WIDTHS:
        print(f"Building INT{bits} integer model...")
        s_x = Q.choose_input_scale(Xtr, bits, rng)
        m = Q.build_int_model(*weights_numpy(model), s_x, bits, calib_x=Q.quantize(Xtr, s_x, bits))
        qat = QATMLP(model, s_x, bits, m["shift"])
        opt = torch.optim.Adam(qat.parameters(), lr=C.QAT_LR)
        for _ in range(QAT_EPOCHS):
            train_epoch(qat, tXtr, tytr, opt, C.BATCH_SIZE)
        qm = qat.to_int_model()
        results.append((f"INT{bits}", Q.accuracy(qm, Xte, yte),
                        f"ACC_W={qm['acc_w']}, SHIFT={qm['shift']}"))

    chance = 1 / len(C.WORDS)
    print(f"\n{'model':8s}{'test accuracy':>15s}   hardware settings")
    for name, acc, info in results:
        print(f"{name:8s}{100 * acc:14.1f}%   {info}")
    ok = all(acc > 2 * chance for _, acc, _ in results)
    print(f"\nRandom guessing would score {100 * chance:.1f}%.")
    print("OK: the pipeline works." if ok else "PROBLEM: accuracy is too low, something is wrong.")
    print(f"Finished in {time.time() - start:.0f} s. (The full run in train.py reaches about 86%.)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
