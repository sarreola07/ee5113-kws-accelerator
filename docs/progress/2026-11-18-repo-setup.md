# Repository and environment set up

- **Date:** 2026-11-18
- **Author:** sarreola07
- **Branch / commit:** main, initial commit
- **Machine(s):** cloud Linux session → GitHub

## What was done
- Created the private GitHub repo `sarreola07/ee5113-kws-accelerator` with the full project structure from the proposal.
- Python:
  - `kws_common.py` holds the **bit-exact integer golden model**.
  - `train.py` trains the float model on Speech Commands with words yes/no/on/off/up/down, using 10 MFCC × 25 frames = 250 inputs.
  - `quantize_export.py` writes INT8 and INT4 ROMs, params and test vectors.
- RTL: one time-shared MAC (`mac.v`) inside an FC engine (`fc_layer.v`) that `kws_top.v` reuses for both layers, plus `relu.v` (requantize) and `argmax.v`.
- Self-checking testbenches:
  - `tb/kws_tb.v` checks the RTL against Python.
  - `tb/fpga_tb.v` checks the board-level top.
- ASIC flow scripts for crosby3: Genus synthesis, Innovus P&R with an MMMC setup, and the `flow/run.sh` driver.
- FPGA: the `fpga_top.v` demo (switches pick a clip, BTNC runs it, the 7-segment display shows the word). Pin files for **Nexys 4** and **Nexys 4 DDR/A7** were taken from Digilent's master XDC files. Non-project Vivado build and program scripts.
- Docs:
  - `docs/SETUP.md` (environment guide)
  - `CLAUDE.md` (Claude must log every milestone here and keep SETUP.md current)
  - this progress-log system

## How to reproduce / load it
```bash
# where: any laptop (see docs/SETUP.md §2 for installing git/python/iverilog)
git clone https://github.com/sarreola07/ee5113-kws-accelerator.git
cd ee5113-kws-accelerator
./sim/run_sim.sh int8 iverilog     # TEST PASSED, 50/50 clips match golden
./sim/run_sim.sh int4 iverilog     # TEST PASSED
./sim/run_sim.sh int8 fpga         # TEST PASSED (board-level)
```
The committed `weights/` were generated with `python python/quantize_export.py --synthetic`.
They are **random placeholder weights** for checking the hardware, not a trained model.

## Files added / changed
| File | What it is | Used by |
|------|-----------|---------|
| `python/*.py` | training, quantization, golden model | laptop |
| `weights/int8/*`, `weights/int4/*` | generated ROMs, params, test vectors (synthetic for now) | sim, Genus, Innovus, Vivado |
| `rtl/*.v` | accelerator | all flows |
| `tb/*.v`, `sim/run_sim.sh` | testbenches + runner | laptop / crosby3 |
| `flow/**` | Genus/Innovus scripts, library config | crosby3 |
| `fpga/**` | Nexys 4 top, XDC, Vivado scripts | Windows + Vivado |
| `docs/SETUP.md`, `CLAUDE.md`, `docs/progress/` | shared documentation | everyone |

## Results (synthetic weights, so only hardware correctness matters here)
| Metric | INT8 | INT4 |
|--------|------|------|
| RTL vs Python golden | 50/50 match | 50/50 match |
| Cycles per clip | 8,312 | 8,312 |
| Agreement with float model | 49/50 | 34/50 |

The INT4 drop is with *random* weights. Real accuracy numbers will come from the trained model.

## Problems hit & fixes
- The FPGA clip loader had a one-cycle data/address skew. The board-level testbench caught it, and it was fixed by registering `load_data`.

## Not yet verified (needs your machines)
- Genus/Innovus have never been run. The library paths in `flow/config.tcl` are **guesses** until `./flow/find_libs.sh` runs on crosby3.
- Vivado has never been run, so timing at 100 MHz on the Artix-7 is unconfirmed.
- It's unknown whether crosby3 can reach GitHub, over SSH or HTTPS.

## Next steps
- [ ] Owner: invite the partner as a collaborator (SETUP §1).
- [ ] Both: laptop setup + clone (SETUP §2).
- [ ] crosby3: Git/SSH key, run `./flow/find_libs.sh`, fix `flow/config.tcl`, then `./flow/run.sh syn int8`.
- [ ] Windows: confirm the board revision, then `fpga\build.bat int8 nexys4ddr program` (or `nexys4`).
- [ ] Laptop: `python python/train.py` → `python python/quantize_export.py` → re-run sims → commit real weights.
