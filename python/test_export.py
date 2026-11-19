"""Tests for quantize_export.py and for the committed weights/ folders.

The weights test decodes the ROMs in weights/<prec>/kws_rom.v, runs the
integer golden model on test_x.mem and checks the result against golden.mem,
so it works for the synthetic placeholder weights and for real trained ones.
"""
import os
import re
import subprocess
import sys
import tempfile
import unittest

import numpy as np

import quantize_export as qe
from kws_common import N_HID, N_IN, N_OUT, PRECISIONS, int_forward

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEIGHTS = os.path.join(ROOT, "weights")


def read_text(path):
    with open(path) as f:
        return f.read()


def read_params(path):
    return {k: int(v) for k, v in re.findall(r"`define KWS_(\w+) (-?\d+)", read_text(path))}


def read_roms(path):
    """{module name: np.array of ROM contents} decoded from kws_rom.v."""
    roms, cur = {}, None
    for line in read_text(path).splitlines():
        m = re.match(r"module (\w+)", line)
        if m:
            cur = roms.setdefault(m.group(1), {})
            continue
        m = re.match(r"\s*\d+'d(\d+): data <= (-?)\d+'sd(\d+);", line)
        if m and cur is not None:
            cur[int(m.group(1))] = -int(m.group(3)) if m.group(2) else int(m.group(3))
    return {k: np.array([v[i] for i in range(len(v))], dtype=np.int64) for k, v in roms.items()}


def read_mem(path, bits=None):
    vals = [int(t, 16) for t in read_text(path).split()]
    if bits:                                         # two's complement
        vals = [v - (1 << bits) if v >= 1 << (bits - 1) else v for v in vals]
    return np.array(vals, dtype=np.int64)


class TestSelection(unittest.TestCase):
    def test_round_robin_over_words(self):
        y = np.repeat(np.arange(N_OUT), 20)              # sorted by word: the worst case
        sel = qe.select_sim_clips(y, 50, seed=0)
        self.assertEqual(len(sel), 50)
        self.assertEqual(list(y[sel][:12]), list(range(N_OUT)) * 2)
        self.assertEqual(len(set(sel.tolist())), 50)
        np.testing.assert_array_equal(sel, qe.select_sim_clips(y, 50, seed=0))

    def test_word_running_out(self):
        y = np.array([0] * 10 + [1] * 2)
        sel = qe.select_sim_clips(y, 8, seed=3)
        self.assertEqual(list(y[sel]), [0, 1, 0, 1, 0, 0, 0, 0])


class TestSyntheticExport(unittest.TestCase):
    def test_deterministic_and_self_consistent(self):
        with tempfile.TemporaryDirectory() as a, tempfile.TemporaryDirectory() as b:
            for d in (a, b):
                subprocess.run([sys.executable, os.path.join(ROOT, "python", "quantize_export.py"),
                                "--synthetic", "--out-dir", d], check=True, capture_output=True)
            for prec in PRECISIONS:
                for f in ("kws_rom.v", "kws_params.vh", "test_x.mem", "golden.mem", "fpga_clips_rom.v"):
                    with open(os.path.join(a, prec, f), "rb") as fa, open(os.path.join(b, prec, f), "rb") as fb:
                        self.assertEqual(fa.read(), fb.read(), f"{prec}/{f} differs between runs")
                check_folder(self, os.path.join(a, prec), prec)


def check_folder(tc, folder, prec):
    bits = PRECISIONS[prec]
    prm = read_params(os.path.join(folder, "kws_params.vh"))
    tc.assertEqual(prm["DATA_W"], bits)
    tc.assertEqual((prm["N_IN"], prm["N_HID"], prm["N_OUT"]), (N_IN, N_HID, N_OUT))
    roms = read_roms(os.path.join(folder, "kws_rom.v"))
    w1 = roms["kws_w1_rom"].reshape(N_HID, N_IN)
    w2 = roms["kws_w2_rom"].reshape(N_OUT, N_HID)
    q = (1 << (bits - 1)) - 1
    tc.assertLessEqual(max(abs(w1).max(), abs(w2).max()), q, "weights exceed the bit width")
    x = read_mem(os.path.join(folder, "test_x.mem"), bits).reshape(prm["N_TEST"], N_IN)
    cls, _, _ = int_forward(x, w1, roms["kws_b1_rom"], w2, roms["kws_b2_rom"], prm["SHIFT1"], bits)
    np.testing.assert_array_equal(cls, read_mem(os.path.join(folder, "golden.mem")),
                                  f"{prec}: golden.mem does not match the ROM contents")


class TestCommittedWeights(unittest.TestCase):
    def test_every_weights_folder(self):
        found = [p for p in PRECISIONS if os.path.exists(os.path.join(WEIGHTS, p, "kws_rom.v"))]
        self.assertIn("int8", found)
        self.assertIn("int4", found)
        for prec in found:
            with self.subTest(prec=prec):
                check_folder(self, os.path.join(WEIGHTS, prec), prec)


if __name__ == "__main__":
    unittest.main()
