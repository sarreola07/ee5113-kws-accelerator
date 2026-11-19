"""Makes the FPGA memory files (fpga/mem/) from the hardware export in weights/.

    python fpga/gen_fpga_mem.py [path/to/weights]

For each precision (int8, int4) it writes, with unique names so Vivado can hold
both sets in one project:
  <p>_weights.mem   8192 weights (same as weights/)
  <p>_biases.mem    38 biases padded to 64 entries (b_addr is 6 bits)
  <p>_inputs256.mem 200 test clips, each padded from 250 to 256 values, so the
                    FPGA can address a clip as {clip, x_addr} without an adder
  <p>_expected.mem  class the Python integer model predicts for each clip
  <p>_labels.mem    true word of each clip
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
if len(sys.argv) > 1:
    HW = Path(sys.argv[1])
else:  # shared-folder layout first, then the original course-folder layout
    HW = HERE.parent / "weights"          # repo layout: fpga/ next to weights/
OUT = HERE / "mem"
OUT.mkdir(exist_ok=True)


def lines(path):
    return [l.strip() for l in path.read_text().split("\n") if l.strip()]


for p in ("int8", "int4"):
    d = HW / p
    zero_x = "0" * len(lines(d / "test_inputs.mem")[0])
    zero_b = "0" * len(lines(d / "biases.mem")[0])

    w = lines(d / "weights.mem")
    assert len(w) == 8192
    (OUT / f"{p}_weights.mem").write_text("\n".join(w) + "\n")

    b = lines(d / "biases.mem")
    assert len(b) == 38
    (OUT / f"{p}_biases.mem").write_text("\n".join(b + [zero_b] * (64 - len(b))) + "\n")

    x = lines(d / "test_inputs.mem")
    assert len(x) == 200 * 250
    padded = []
    for c in range(200):
        padded += x[c * 250:(c + 1) * 250] + [zero_x] * 6
    (OUT / f"{p}_inputs256.mem").write_text("\n".join(padded) + "\n")

    for src, dst in (("test_expected.mem", "expected"), ("test_labels.mem", "labels")):
        v = lines(d / src)
        assert len(v) == 200
        (OUT / f"{p}_{dst}.mem").write_text("\n".join(v) + "\n")

    print(f"{p}: written to {OUT}")
