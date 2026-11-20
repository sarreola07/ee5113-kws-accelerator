"""Makes the FPGA memory files (fpga/mem/) from the hardware export in weights/.

    python fpga/gen_fpga_mem.py [path/to/weights]           # write fpga/mem/*.mem
    python fpga/gen_fpga_mem.py --check [path/to/weights]   # exit 1 if fpga/mem is out of date

For each precision (int8, int4) it writes, with unique names so Vivado can hold
both sets in one project:
  <p>_weights.mem   8192 weights (same as weights/)
  <p>_biases.mem    38 biases padded to 64 entries (b_addr is 6 bits)
  <p>_inputs256.mem 200 test clips, each padded from 250 to 256 values, so the
                    FPGA can address a clip as {clip, x_addr} without an adder
  <p>_expected.mem  class the Python integer model predicts for each clip
  <p>_labels.mem    true word of each clip
  <p>_logits8.mem   the 6 output scores Python computes for each clip, padded to
                    8 per clip (address {clip, score}); the board compares every score
  <p>_check.mem     4 x 16-bit words: magic 4B57, then the sums (mod 2^16) of the
                    expected classes, the labels and the raw score words. The board
                    recomputes them during run-all, so a missing or damaged golden-data
                    file (expected, labels, logits8, check) shows "Err" instead of a
                    false PASS. A missing weights, biases or inputs file makes every clip
                    fail instead (typically "F000   0"). --check finds an fpga/mem that is
                    older than weights/ (the board would still pass, against old data).
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
args = [a for a in sys.argv[1:] if a != "--check"]
CHECK_ONLY = "--check" in sys.argv[1:]
HW = Path(args[0]) if args else HERE.parent / "weights"
OUT = HERE / "mem"
MAGIC = 0x4B57                              # "KW"
N_CLIPS, N_IN, N_OUT = 200, 250, 6


def lines(path):
    return [l.strip() for l in path.read_text().split("\n") if l.strip()]


def files_for(p):
    """{file name: content} for precision p."""
    d = HW / p
    zero_x = "0" * len(lines(d / "test_inputs.mem")[0])
    zero_b = "0" * len(lines(d / "biases.mem")[0])
    zero_l = "0" * len(lines(d / "test_logits.mem")[0])
    out = {}

    w = lines(d / "weights.mem")
    assert len(w) == 8192
    out[f"{p}_weights.mem"] = w

    b = lines(d / "biases.mem")
    assert len(b) == 38
    out[f"{p}_biases.mem"] = b + [zero_b] * (64 - len(b))

    x = lines(d / "test_inputs.mem")
    assert len(x) == N_CLIPS * N_IN
    padded = []
    for c in range(N_CLIPS):
        padded += x[c * N_IN:(c + 1) * N_IN] + [zero_x] * (256 - N_IN)
    out[f"{p}_inputs256.mem"] = padded

    for src, dst in (("test_expected.mem", "expected"), ("test_labels.mem", "labels")):
        v = lines(d / src)
        assert len(v) == N_CLIPS
        out[f"{p}_{dst}.mem"] = v

    lg = lines(d / "test_logits.mem")
    assert len(lg) == N_CLIPS * N_OUT
    lg8 = []
    for c in range(N_CLIPS):
        lg8 += lg[c * N_OUT:(c + 1) * N_OUT] + [zero_l] * (8 - N_OUT)
    out[f"{p}_logits8.mem"] = lg8

    s_exp = sum(int(v, 16) for v in out[f"{p}_expected.mem"]) % 65536
    s_lab = sum(int(v, 16) for v in out[f"{p}_labels.mem"]) % 65536
    s_lg = sum(int(v, 16) for v in lg) % 65536
    out[f"{p}_check.mem"] = [f"{MAGIC:04x}", f"{s_exp:04x}", f"{s_lab:04x}", f"{s_lg:04x}"]
    return {name: "\n".join(v) + "\n" for name, v in out.items()}


stale = []
for p in ("int8", "int4"):
    for name, text in files_for(p).items():
        path = OUT / name
        if CHECK_ONLY:
            if not path.exists() or path.read_text() != text:
                stale.append(name)
        else:
            OUT.mkdir(exist_ok=True)
            path.write_text(text)
    if not CHECK_ONLY:
        print(f"{p}: written to {OUT}")

if CHECK_ONLY:
    if stale:
        print("fpga/mem is OUT OF DATE with weights/ - run: python fpga/gen_fpga_mem.py")
        print("  differs: " + ", ".join(stale))
        sys.exit(1)
    print("fpga/mem matches weights/")
