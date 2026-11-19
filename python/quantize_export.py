#!/usr/bin/env python3
"""Quantize the trained float model to INT8 / INT6 / INT4 and export everything
the hardware flows need into weights/<precision>/ :

    kws_params.vh     `defines (sizes, bit width, shift) included by the RTL
    kws_rom.v         synthesizable weight/bias ROMs (case statements), used by
                      simulation, Genus/Innovus and Vivado alike
    fpga_clips_rom.v  16 test clips stored on the FPGA for the board demo
    test_x.mem        the clips used in simulation, one quantized feature per line (hex)
    test_label.mem    true word index per exported clip
    golden.mem        class predicted by the integer Python model (HW must match)
    summary.json      accuracy on the FULL test split, agreement with the float
                      model, confusion matrix, shift, scales

The exported clips are picked round-robin over the 6 words (seeded), so every
word appears in simulation and FPGA switch setting k shows word k mod 6.

Usage:
    python python/quantize_export.py                     # real model (after train.py)
    python python/quantize_export.py --synthetic         # random model, no dataset needed
    python python/quantize_export.py --precisions int8,int4
"""
import argparse
import hashlib
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kws_common import (ACC_W, N_HID, N_IN, N_OUT, PRECISIONS, WORDS,  # noqa: E402
                        choose_shift, feature_cfg_json, int_forward, quantize_sym, to_hex)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
N_FPGA_CLIPS = 16


# ------------------------------------------------------------------ inputs ---
def synthetic_data(args):
    """Random model and clips: lets the hardware be tested without a dataset."""
    rng = np.random.default_rng(args.seed)
    m = {
        "w1": rng.normal(0, 0.15, (N_HID, N_IN)),
        "b1": rng.normal(0, 0.1, N_HID),
        "w2": rng.normal(0, 0.3, (N_OUT, N_HID)),
        "b2": rng.normal(0, 0.1, N_OUT),
    }
    x = rng.normal(0, 1.0, (args.n_test, N_IN))
    rng.integers(0, N_OUT, args.n_test)       # keeps the random stream as in earlier versions
    y = float_forward(m, x)                   # synthetic "labels" = float prediction
    return m, {"x_test": x, "y_test": y, "x_val": None, "y_val": None, "calib": x,
               "synthetic": True, "model_sha256": None, "eval_split": "synthetic",
               "calib_desc": {"source": "the synthetic clips", "n": int(len(x))}}


def file_sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def real_data(args):
    for p in (args.model, args.features):
        if not os.path.exists(p):
            sys.exit(f"missing {p}: run  python python/train.py  first (or use --synthetic)")
    model = np.load(args.model)
    feats = np.load(args.features)
    if str(feats["cfg"]) != feature_cfg_json():
        sys.exit("features.npz was built with different feature settings: "
                 "run  python python/train.py --rebuild-features")
    meta = json.loads(str(model["meta"])) if "meta" in model.files else {}
    if meta.get("feature_cfg") not in (None, feature_cfg_json()):
        sys.exit("model.npz was trained on different features: retrain with python/train.py")
    m = {k: model[k].astype(np.float64) for k in ("w1", "b1", "w2", "b2")}
    want = {"w1": (N_HID, N_IN), "b1": (N_HID,), "w2": (N_OUT, N_HID), "b2": (N_OUT,)}
    for k, shape in want.items():
        if m[k].shape != shape:
            sys.exit(f"model {k} has shape {m[k].shape}, expected {shape}")
    x_train = feats["x_train"]
    rng = np.random.default_rng(args.calib_seed)
    n = min(args.calib_n, len(x_train))
    calib = x_train[np.sort(rng.choice(len(x_train), n, replace=False))]
    return m, {"x_test": feats["x_test"], "y_test": feats["y_test"].astype(np.int64),
               "x_val": feats["x_val"], "y_val": feats["y_val"].astype(np.int64),
               "calib": calib, "synthetic": False, "model_sha256": file_sha256(args.model),
               "eval_split": "test",
               "calib_desc": {"source": "random training clips", "n": int(n),
                              "seed": args.calib_seed}}


# ------------------------------------------------------------ the maths ---
def float_forward(m, x):
    h = np.maximum(x @ m["w1"].T + m["b1"], 0)
    return np.argmax(h @ m["w2"].T + m["b2"], axis=1)


def quantize_model(m, calib, bits):
    xq_cal, s_x = quantize_sym(calib, bits)
    w1q, s_w1 = quantize_sym(m["w1"], bits)
    b1q = np.round(m["b1"] / (s_x * s_w1)).astype(np.int64)
    acc1 = xq_cal @ w1q.T + b1q
    shift1 = choose_shift(acc1, bits)
    s_h = s_x * s_w1 * (1 << shift1)
    w2q, s_w2 = quantize_sym(m["w2"], bits)
    b2q = np.round(m["b2"] / (s_h * s_w2)).astype(np.int64)
    return dict(w1=w1q, b1=b1q, w2=w2q, b2=b2q, s_x=s_x, s_w1=s_w1, s_w2=s_w2, shift1=shift1)


def int_predict(q, x, bits):
    xq, _ = quantize_sym(x, bits, scale=q["s_x"])
    pred, _, _ = int_forward(xq, q["w1"], q["b1"], q["w2"], q["b2"], q["shift1"], bits)
    return xq, pred


def select_sim_clips(y, n, seed=0):
    """n clip indices cycling through the words (0,1,...,5,0,1,...), with a
    seeded random order inside each word. A word that runs out is skipped."""
    rng = np.random.default_rng(seed)
    pools = [list(rng.permutation(np.flatnonzero(y == c))) for c in range(N_OUT)]
    out = []
    while len(out) < n and any(pools):
        for pool in pools:
            if pool and len(out) < n:
                out.append(int(pool.pop(0)))
    return np.array(out, dtype=np.int64)


def confusion(y_true, y_pred, n=N_OUT):
    """rows = true word, columns = predicted word"""
    cm = np.zeros((n, n), dtype=np.int64)
    np.add.at(cm, (np.asarray(y_true, dtype=np.int64), np.asarray(y_pred, dtype=np.int64)), 1)
    return cm


def mean(a):
    return float(np.mean(a)) if len(a) else float("nan")


# ------------------------------------------------------------- outputs ---
def rom_module(name, values, bits, comment):
    n = len(values)
    aw = max(1, int(np.ceil(np.log2(n))))
    lines = [f"// {comment}",
             f"// AUTO-GENERATED by python/quantize_export.py - do not edit by hand.",
             f"module {name} (",
             f"    input  wire                 clk,",
             f"    input  wire [{aw-1}:0]          addr,",
             f"    output reg  signed [{bits-1}:0] data",
             f");",
             f"    always @(posedge clk) begin",
             f"        case (addr)"]
    for i, v in enumerate(values):
        v = int(v)
        lit = f"-{bits}'sd{-v}" if v < 0 else f"{bits}'sd{v}"
        lines.append(f"            {aw}'d{i}: data <= {lit};")
    lines += [f"            default: data <= {bits}'sd0;",
              "        endcase",
              "    end",
              "endmodule", ""]
    return "\n".join(lines)


def export(prec, bits, q, xq, y, golden, out_dir, summary):
    out = os.path.join(out_dir, prec)
    os.makedirs(out, exist_ok=True)
    n_test = len(xq)
    with open(os.path.join(out, "kws_params.vh"), "w") as f:
        f.write(f"// AUTO-GENERATED by python/quantize_export.py ({prec})\n"
                f"`define KWS_DATA_W {bits}\n`define KWS_ACC_W {ACC_W}\n"
                f"`define KWS_N_IN {N_IN}\n`define KWS_N_HID {N_HID}\n"
                f"`define KWS_N_OUT {N_OUT}\n`define KWS_SHIFT1 {q['shift1']}\n"
                f"`define KWS_N_TEST {n_test}\n`define KWS_N_FPGA_CLIPS {N_FPGA_CLIPS}\n")
    roms = [
        rom_module("kws_w1_rom", q["w1"].reshape(-1), bits, f"Layer-1 weights [{N_HID}][{N_IN}] row-major ({prec})"),
        rom_module("kws_b1_rom", q["b1"], ACC_W, f"Layer-1 biases ({prec})"),
        rom_module("kws_w2_rom", q["w2"].reshape(-1), bits, f"Layer-2 weights [{N_OUT}][{N_HID}] row-major ({prec})"),
        rom_module("kws_b2_rom", q["b2"], ACC_W, f"Layer-2 biases ({prec})"),
    ]
    with open(os.path.join(out, "kws_rom.v"), "w") as f:
        f.write("\n".join(roms))
    nclips = min(N_FPGA_CLIPS, n_test)
    clips = np.zeros((N_FPGA_CLIPS, N_IN), dtype=np.int64)
    clips[:nclips] = xq[:nclips]
    with open(os.path.join(out, "fpga_clips_rom.v"), "w") as f:
        f.write(rom_module("fpga_clips_rom", clips.reshape(-1), bits,
                           f"{N_FPGA_CLIPS} test clips x {N_IN} features for the board demo ({prec})"))
    with open(os.path.join(out, "test_x.mem"), "w") as f:
        f.writelines(to_hex(v, bits) + "\n" for v in xq.reshape(-1))
    with open(os.path.join(out, "test_label.mem"), "w") as f:
        f.writelines(f"{int(v):x}\n" for v in y)
    with open(os.path.join(out, "golden.mem"), "w") as f:
        f.writelines(f"{int(v):x}\n" for v in golden)
    summary = dict(summary, precision=prec, bits=bits, shift1=int(q["shift1"]),
                   input_scale=float(q["s_x"]), n_test=int(n_test),
                   fpga_clip_labels=[WORDS[int(v)] for v in y[:nclips]])
    with open(os.path.join(out, "summary.json"), "w") as f:
        json.dump(summary, f, indent=2)
    return summary


def warn_stale(out_dir, done, model_sha):
    for prec in PRECISIONS:
        p = os.path.join(out_dir, prec, "summary.json")
        if prec in done or not os.path.exists(p):
            continue
        try:
            old = json.load(open(p)).get("model_sha256")
        except ValueError:
            old = "?"
        if old != model_sha:
            print(f"WARNING: weights/{prec} was exported from a different model. "
                  f"Re-export it (--precisions {prec}) before using it.")


# ---------------------------------------------------------------- main ---
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--synthetic", action="store_true", help="random weights/clips (no dataset needed)")
    ap.add_argument("--precisions", default=",".join(PRECISIONS),
                    help="comma-separated subset of " + ",".join(PRECISIONS) + " (default: all)")
    ap.add_argument("--n-test", type=int, default=50, help="clips exported for simulation")
    ap.add_argument("--seed", type=int, default=1, help="random seed for --synthetic")
    ap.add_argument("--sel-seed", type=int, default=0, help="seed for picking the exported clips")
    ap.add_argument("--calib-n", type=int, default=2000, help="training clips used to choose scales")
    ap.add_argument("--calib-seed", type=int, default=0)
    ap.add_argument("--model", default=os.path.join(ROOT, "python", "checkpoints", "model.npz"))
    ap.add_argument("--features", default=os.path.join(ROOT, "python", "data", "features.npz"))
    ap.add_argument("--out-dir", default=os.path.join(ROOT, "weights"))
    args = ap.parse_args()

    precs = [p.strip() for p in args.precisions.split(",") if p.strip()]
    bad = [p for p in precs if p not in PRECISIONS]
    if bad:
        sys.exit(f"unknown precision(s) {bad}; choose from {list(PRECISIONS)}")

    m, data = synthetic_data(args) if args.synthetic else real_data(args)
    x, y = data["x_test"], data["y_test"]
    pred_float = float_forward(m, x)
    acc_float = mean(pred_float == y)
    have_val = data["x_val"] is not None
    val_float = mean(float_forward(m, data["x_val"]) == data["y_val"]) if have_val else None
    if data["synthetic"]:
        sel = np.arange(min(args.n_test, len(x)))
    else:
        sel = select_sim_clips(y, args.n_test, args.sel_seed)

    print(f"float model: accuracy {acc_float:.4f} on {len(y)} {data['eval_split']} clips"
          + (f", validation {val_float:.4f}" if have_val else ""))
    for prec in precs:
        bits = PRECISIONS[prec]
        q = quantize_model(m, data["calib"], bits)
        xq, pred_int = int_predict(q, x, bits)
        acc_int = mean(pred_int == y)
        val_int = mean(int_predict(q, data["x_val"], bits)[1] == data["y_val"]) if have_val else None
        summary = {
            "words": WORDS,
            "synthetic": data["synthetic"],
            "eval_split": data["eval_split"],
            "n_eval": int(len(y)),
            "float_accuracy": acc_float,
            "int_accuracy": acc_int,
            "int_float_agreement": mean(pred_int == pred_float),
            "val_float_accuracy": val_float,
            "val_int_accuracy": val_int,
            "confusion_int": confusion(y, pred_int).tolist(),
            "sim_subset": {"n": int(len(sel)), "float_accuracy": mean(pred_float[sel] == y[sel]),
                           "int_accuracy": mean(pred_int[sel] == y[sel])},
            "weight_scales": {"w1": float(q["s_w1"]), "w2": float(q["s_w2"])},
            "model_sha256": data["model_sha256"],
            "feature_cfg": json.loads(feature_cfg_json()),
            "calib": data["calib_desc"],
        }
        s = export(prec, bits, q, xq[sel], y[sel], pred_int[sel], args.out_dir, summary)
        dest = os.path.abspath(os.path.join(args.out_dir, prec))
        shown = os.path.relpath(dest, ROOT) if dest.startswith(ROOT + os.sep) else dest
        print(f"[{prec}] shift1={s['shift1']}  int accuracy={acc_int:.4f}"
              + (f"  (validation {val_int:.4f})" if have_val else "")
              + f"  agreement with float={s['int_float_agreement']:.4f}  -> {shown}/")
    warn_stale(args.out_dir, precs, data["model_sha256"])


if __name__ == "__main__":
    main()
