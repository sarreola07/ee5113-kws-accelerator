# python/ — model training, quantization and the golden model

Run this on a laptop with the venv from `docs/SETUP.md` §2 activated.

| Step | Command | Output (git status) |
|------|---------|---------------------|
| 1. Train the float model (downloads ~2.3 GB once) | `python python/train.py` | `python/data/`, `python/checkpoints/model.npz` (ignored) |
| 2. Quantize + export INT8/INT4 | `python python/quantize_export.py` | `weights/int8/`, `weights/int4/` (**commit these**) |
| 3. Check hardware == Python | `./sim/run_sim.sh int8` and `int4` | `TEST PASSED` |

- `--synthetic` on step 2 skips steps 1 and uses random weights. Use it only for hardware testing.
- The network size and word list are set in `kws_common.py` (`WORDS`, `N_MFCC`, `N_FRAMES`, `N_HID`).
  If you change them, re-export and re-run all simulations. FPGA note: the 7-segment word table in
  `fpga/fpga_top.v` follows the `WORDS` order.
- Each run writes accuracy (float vs integer) to `weights/<prec>/summary.json`. Use those numbers in the report.
