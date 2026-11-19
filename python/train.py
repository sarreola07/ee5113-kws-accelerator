"""Step 2: train the float network, then build INT8 and INT4 versions.

    python python/train.py
    python python/train.py --features data/features_synthetic.npz   # quick pipeline test

For each bit width two methods are compared:
  PTQ - post-training quantization: round the trained float weights directly
  QAT - quantization-aware training: fine-tune with the integer hardware math in the loop
The better one (on the validation set) is saved as results/qmodel_int<bits>.npz for export.
All INT accuracies are measured with the bit-exact integer model in quant.py.
"""
import argparse
import copy
import csv
import sys

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

import config as C
import quant as Q


# ---------------------------------------------------------------- models
class FloatMLP(nn.Module):
    def __init__(self, n_in, n_hidden, n_out, dropout):
        super().__init__()
        self.fc1 = nn.Linear(n_in, n_hidden)
        self.fc2 = nn.Linear(n_hidden, n_out)
        self.drop = nn.Dropout(dropout)

    def forward(self, x):
        return self.fc2(self.drop(torch.relu(self.fc1(x))))


def _round_ste(x):
    """Round half up in the forward pass, identity gradient in the backward pass."""
    return x + (torch.floor(x + 0.5) - x).detach()


def _fake_quant(x, scale, lo, hi):
    return torch.clamp(_round_ste(x / scale), lo, hi) * scale


class QATMLP(nn.Module):
    """Same weights as FloatMLP, but the forward pass copies the integer hardware math."""

    def __init__(self, float_model, s_x, bits, shift):
        super().__init__()
        self.fc1 = copy.deepcopy(float_model.fc1)
        self.fc2 = copy.deepcopy(float_model.fc2)
        self.s_x, self.bits, self.q, self.shift = s_x, bits, Q.qmax(bits), shift

    def forward(self, x):
        q = self.q
        s_w1 = self.fc1.weight.detach().abs().max() / q
        s_w2 = self.fc2.weight.detach().abs().max() / q
        s_acc1 = self.s_x * s_w1
        x = _fake_quant(x, self.s_x, -q, q)
        w1 = _fake_quant(self.fc1.weight, s_w1, -q, q)
        b1 = _round_ste(self.fc1.bias / s_acc1) * s_acc1
        s_h = s_acc1 * 2.0 ** self.shift
        h = _fake_quant(torch.relu(x @ w1.T + b1), s_h, 0, q)
        w2 = _fake_quant(self.fc2.weight, s_w2, -q, q)
        b2 = _round_ste(self.fc2.bias / (s_h * s_w2)) * (s_h * s_w2)
        return h @ w2.T + b2

    def to_int_model(self, calib_x=None):
        """Integer model with the current shift, or a re-picked shift if calib_x is given."""
        shift = None if calib_x is not None else self.shift
        return Q.build_int_model(*weights_numpy(self), self.s_x, self.bits,
                                 shift=shift, calib_x=calib_x)


def weights_numpy(model):
    return [p.detach().cpu().numpy().astype(np.float64)
            for p in (model.fc1.weight, model.fc1.bias, model.fc2.weight, model.fc2.bias)]


# ---------------------------------------------------------------- training helpers
def train_epoch(model, X, y, opt, batch_size):
    model.train()
    order = torch.randperm(len(X))
    for i in range(0, len(X), batch_size):
        idx = order[i:i + batch_size]
        loss = F.cross_entropy(model(X[idx]), y[idx])
        opt.zero_grad()
        loss.backward()
        opt.step()


@torch.no_grad()
def predict(model, X):
    model.eval()
    return model(X).argmax(dim=1).numpy()


def confusion(y_true, y_pred, n):
    cm = np.zeros((n, n), np.int64)
    np.add.at(cm, (y_true, y_pred), 1)
    return cm


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--features", default=str(C.FEATURES_FILE))
    ap.add_argument("--float-epochs", type=int, default=C.FLOAT_EPOCHS)
    ap.add_argument("--qat-epochs", type=int, default=C.QAT_EPOCHS)
    args = ap.parse_args()

    torch.manual_seed(C.SEED)
    rng = np.random.default_rng(C.SEED)
    d = np.load(args.features)
    words = [str(w) for w in d["words"]]
    Xtr, ytr, Xva, yva, Xte, yte = (d[k] for k in
                                    ("X_train", "y_train", "X_val", "y_val", "X_test", "y_test"))
    tXtr, tytr = torch.from_numpy(Xtr), torch.from_numpy(ytr)
    tXva, tXte = torch.from_numpy(Xva), torch.from_numpy(Xte)
    n_in, n_out = Xtr.shape[1], len(words)
    print(f"Data: {len(ytr)} train / {len(yva)} val / {len(yte)} test clips, "
          f"{n_in} inputs, words = {words}")
    C.RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    rows, confusions = [], {}
    history = []        # (model, epoch, val_acc) for the training-curve figure

    def record(name, bits, method, val_acc, test_pred, m=None):
        val_acc = round(val_acc, 4)
        test_acc = round(float(np.mean(test_pred == yte)), 4)
        n_weights = n_in * C.N_HIDDEN + C.N_HIDDEN * n_out
        rows.append({"model": name, "bits": bits, "method": method,
                     "val_acc": val_acc, "test_acc": test_acc,
                     "weight_memory_bytes": n_weights * bits // 8,
                     "shift": m["shift"] if m else "", "acc_w": m["acc_w"] if m else "",
                     "exported": ""})
        confusions[name] = confusion(yte, test_pred, n_out)
        print(f"  {name:10s} val {100 * val_acc:5.1f}%   test {100 * test_acc:5.1f}%")
        return test_acc

    # ---- 1. float model
    print(f"\nTraining FP32 model ({args.float_epochs} epochs)...")
    model = FloatMLP(n_in, C.N_HIDDEN, n_out, C.DROPOUT)
    opt = torch.optim.Adam(model.parameters(), lr=C.FLOAT_LR, weight_decay=C.WEIGHT_DECAY)
    best_val, best_state = -1.0, None
    for epoch in range(args.float_epochs):
        train_epoch(model, tXtr, tytr, opt, C.BATCH_SIZE)
        val = float(np.mean(predict(model, tXva) == yva))
        history.append(("FP32", epoch + 1, val))
        if val > best_val:
            best_val, best_state = val, copy.deepcopy(model.state_dict())
        if (epoch + 1) % 10 == 0:
            print(f"  epoch {epoch + 1:3d}  val {100 * val:5.1f}%")
    model.load_state_dict(best_state)
    torch.save(model.state_dict(), C.RESULTS_DIR / "float_model.pt")
    W1, b1, W2, b2 = weights_numpy(model)
    np.savez(C.RESULTS_DIR / "float_weights.npz", W1=W1, b1=b1, W2=W2, b2=b2)
    record("FP32", 32, "float", best_val, predict(model, tXte))

    # ---- 2. integer models
    calib = Xtr[rng.choice(len(Xtr), min(2000, len(Xtr)), replace=False)]
    for bits in C.BIT_WIDTHS:
        print(f"\nINT{bits}:")
        s_x = Q.choose_input_scale(Xtr, bits, rng)
        calib_x = Q.quantize(calib, s_x, bits)

        # PTQ
        ptq = Q.build_int_model(*weights_numpy(model), s_x, bits, calib_x=calib_x)
        ptq_val = Q.accuracy(ptq, Xva, yva)
        record(f"INT{bits}-PTQ", bits, "PTQ", ptq_val,
               Q.int_forward(ptq, Q.quantize(Xte, s_x, bits))[0], ptq)

        # QAT: re-pick the shift during the first 70% of epochs, then freeze it
        qat = QATMLP(model, s_x, bits, ptq["shift"])
        opt = torch.optim.Adam(qat.parameters(), lr=C.QAT_LR, weight_decay=C.WEIGHT_DECAY)
        best_val, best_state, best_shift = -1.0, None, qat.shift
        history.append((f"INT{bits}-QAT", 0, ptq_val))      # epoch 0 = the PTQ model
        for epoch in range(args.qat_epochs):
            if 0 < epoch < int(0.7 * args.qat_epochs):
                qat.shift = qat.to_int_model(calib_x=calib_x)["shift"]
            train_epoch(qat, tXtr, tytr, opt, C.BATCH_SIZE)
            val = Q.accuracy(qat.to_int_model(), Xva, yva)
            history.append((f"INT{bits}-QAT", epoch + 1, val))
            if val > best_val:
                best_val, best_state, best_shift = val, copy.deepcopy(qat.state_dict()), qat.shift
        qat.load_state_dict(best_state)
        qat.shift = best_shift
        qm = qat.to_int_model()
        int_pred = Q.int_forward(qm, Q.quantize(Xte, s_x, bits))[0]
        record(f"INT{bits}-QAT", bits, "QAT", best_val, int_pred, qm)

        # Sanity check: PyTorch fake-quant model and integer model should agree
        agree = float(np.mean(predict(qat, tXte) == int_pred))
        print(f"  fake-quant vs integer model agreement on test set: {100 * agree:.2f}%")

        chosen, method = (qm, "QAT") if best_val >= ptq_val else (ptq, "PTQ")
        Q.save_int_model(C.RESULTS_DIR / f"qmodel_int{bits}.npz", chosen, words)
        next(r for r in rows if r["model"] == f"INT{bits}-{method}")["exported"] = "yes"
        print(f"  -> saved {method} model: SHIFT={chosen['shift']}, ACC_W={chosen['acc_w']}, "
              f"s_x={chosen['s_x']:.5f}")

    # ---- 3. reports
    with open(C.RESULTS_DIR / "results.csv", "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    with open(C.RESULTS_DIR / "history.csv", "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["model", "epoch", "val_acc"])
        writer.writerows((m, e, round(v, 4)) for m, e, v in history)
    for name, cm in confusions.items():
        with open(C.RESULTS_DIR / f"confusion_{name}.csv", "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(["true \\ predicted"] + words)
            writer.writerows([[w] + list(r) for w, r in zip(words, cm)])

    print("\nSummary (test accuracy uses the bit-exact integer model for INT rows)")
    print(f"{'model':12s}{'val':>8s}{'test':>8s}{'weights':>10s}")
    for r in rows:
        print(f"{r['model']:12s}{100 * r['val_acc']:7.1f}%{100 * r['test_acc']:7.1f}%"
              f"{r['weight_memory_bytes']:>8d} B")
    print(f"\nSaved results to {C.RESULTS_DIR}")


if __name__ == "__main__":
    sys.exit(main())
