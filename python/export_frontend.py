"""Writes weights/frontend.npz: what a PC needs to turn live audio into the
accelerator's integer inputs exactly like the training data. Used by
fpga/kws_live.py (live words on the FPGA board).

    python python/export_frontend.py            # needs python/data/features.npz (prepare_data.py)
    python python/export_frontend.py --verify   # rebuild the 200 hardware test inputs from the
                                                # .wav files and compare with weights/int*/test_inputs.mem

Contents: the training-set mean / std of every feature (only stored in the
git-ignored features.npz before), the words, the MFCC settings, and the input
scale s_x of each precision (results/python/qmodel_int*.npz).
"""
import argparse
import json
import sys

import numpy as np

import config as C
import live_frontend as F
from prepare_data import read_wav, split_files


def export():
    if not C.FEATURES_FILE.exists():
        sys.exit(f"missing {C.FEATURES_FILE}: run python python/prepare_data.py first")
    d = np.load(C.FEATURES_FILE)
    s_x = [float(np.load(C.RESULTS_DIR / f"qmodel_int{b}.npz")["s_x"]) for b in C.BIT_WIDTHS]
    cfg = {k.lower(): getattr(C, k) for k in F.CFG_KEYS}
    np.savez(F.FRONTEND_FILE, mean=d["mean"], std=d["std"], words=np.array(C.WORDS),
             bits=np.array(C.BIT_WIDTHS), s_x=np.array(s_x), cfg=json.dumps(cfg, sort_keys=True))
    print(f"Saved {F.FRONTEND_FILE}  (s_x: " + ", ".join(f"INT{b} {s:.6f}" for b, s in zip(C.BIT_WIDTHS, s_x)) + ")")


def verify():
    """Rebuild weights/int*/test_inputs.mem from the raw .wav files with live_frontend."""
    fe = F.load()
    test = split_files(C.WORDS)["test"]
    rng = np.random.default_rng(C.SEED)                      # the same pick as export_hw.py
    pick = np.sort(rng.choice(len(test), min(C.N_HW_TEST_VECTORS, len(test)), replace=False))
    ok = True
    for bits in C.BIT_WIDTHS:
        ref = np.array([int(v, 16) for v in (C.HW_DIR / f"int{bits}" / "test_inputs.mem").read_text().split()])
        ref = np.where(ref >= 1 << (bits - 1), ref - (1 << bits), ref).reshape(-1, C.N_INPUTS)
        got = np.stack([F.to_inputs(read_wav(test[i][0]), fe, bits) for i in pick])
        bad = int(np.sum(got != ref))
        clips = int(np.sum(np.any(got != ref, axis=1)))
        print(f"INT{bits}: {got.size - bad}/{got.size} inputs identical, {len(pick) - clips}/{len(pick)} clips identical")
        ok &= bad == 0
    print("front end matches the hardware test data bit for bit" if ok else "MISMATCH")
    return ok


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--verify", action="store_true")
    a = ap.parse_args()
    if a.verify:
        sys.exit(0 if verify() else 1)
    export()
