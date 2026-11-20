#!/usr/bin/env python3
"""UART cross-check: the packets fpga/kws_live.py sends, run through the Verilog board design.

    python sim/uart_xcheck.py                       # test clips 2, 77, 199 at INT8 and INT4
    python sim/uart_xcheck.py --clips 0 5 123       # other test clips
    python sim/uart_xcheck.py --wav my_word.wav     # also a recorded word (16 kHz mono 16-bit)

kws_live.encode_infer makes each packet; tb/tb_uart_xcheck.v sends it into fpga/kws_fpga_top.v
through the UART pin and saves the 30-byte reply; kws_live.decode_reply reads it back. The class
and all 6 scores must equal the Python integer model (python/quant.py::int_forward). This checks
the PC side (fpga/kws_live.py) and the board side (fpga/kws_uart_link.v) of the protocol against
each other; tb/tb_fpga_top.v checks the board side with its own Verilog packet maker.

Needs Icarus Verilog (iverilog and vvp on PATH): Linux, crosby3, or macOS (brew install
icarus-verilog). Run folder: work/sim/uart_xcheck/ (git-ignored). Takes about 10 s.
"""
import argparse
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "fpga"))
import kws_live as L        # noqa: E402  (also puts python/ on sys.path)

C, F, Q = L.C, L.F, L.Q
SRCS = ["rtl/kws_accel.v", "fpga/kws_fpga_core.v", "fpga/kws_fpga_top.v", "fpga/uart.v",
        "fpga/kws_uart_link.v", "tb/tb_uart_xcheck.v"]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--clips", type=int, nargs="+", default=[2, 77, 199], help="test clips 0..199")
    ap.add_argument("--wav", help="also send this 16 kHz mono 16-bit .wav file (live front end)")
    a = ap.parse_args()
    for tool in ("iverilog", "vvp"):
        if not shutil.which(tool):
            sys.exit(f"{tool} not found: install Icarus Verilog (see the docstring)")

    # the inputs to send: hardware test clips, and optionally a recorded word
    cases = []
    for bits in C.BIT_WIDTHS:
        x = L.read_mem(C.HW_DIR / f"int{bits}" / "test_inputs.mem", bits).reshape(-1, C.N_INPUTS)
        cases += [(f"INT{bits} test clip {c}", bits, x[c]) for c in a.clips]
    if a.wav:
        fe = F.load()
        audio = F.loudest_window(L.read_wav(a.wav))
        cases += [(f"INT{bits} {Path(a.wav).name}", bits, F.to_inputs(audio, fe, bits)) for bits in C.BIT_WIDTHS]

    run = ROOT / "work" / "sim" / "uart_xcheck"
    run.mkdir(parents=True, exist_ok=True)
    for m in (ROOT / "fpga" / "mem").glob("*.mem"):
        shutil.copy(m, run)
    (run / "packets.mem").write_text("".join(f"{v:02x}\n" for _, bits, x in cases
                                             for v in L.encode_infer(bits, x)))
    replies = run / "replies.mem"
    replies.unlink(missing_ok=True)
    subprocess.run(["iverilog", "-g2005", "-o", "xcheck.vvp"] + [str(ROOT / s) for s in SRCS],
                   cwd=run, check=True)
    subprocess.run(["vvp", "-n", "xcheck.vvp"], cwd=run, check=True)
    raw = bytes(int(t, 16) for t in replies.read_text().split()) if replies.exists() else b""

    models = {b: Q.load_int_model(C.RESULTS_DIR / f"qmodel_int{b}.npz")[0] for b in C.BIT_WIDTHS}
    ok = 0
    for i, (name, bits, x) in enumerate(cases):
        pred, _, logits = Q.int_forward(models[bits], np.asarray(x, dtype=np.int64)[None, :])
        want = [int(v) for v in logits[0]]
        try:
            r = L.decode_reply(raw[30 * i:30 * i + 30])
        except ValueError as e:
            print(f"{name:28s} {e}")
            continue
        same = r["status"] == 0 and r["class"] == pred[0] and r["scores"] == want
        ok += same
        print(f"{name:28s} board {C.WORDS[r['class']]:5s} {r['scores']} {r['cycles']} cycles | "
              f"Python {C.WORDS[pred[0]]:5s} {want}  {'same' if same else 'DIFFERENT'}")
    passed = ok == len(cases)
    print(f"UART CROSS-CHECK {'PASSED' if passed else 'FAILED'}: {ok}/{len(cases)} replies equal Python")
    return passed


if __name__ == "__main__":
    sys.exit(0 if main() else 1)
