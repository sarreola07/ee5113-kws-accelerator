# Alternative design: on-chip ROM / block-RAM version (sarreola07)

This folder is the original version of the repo (up to commit `c4efb29`), moved here
when the two versions of the project were combined on 2026-11-19. File contents were not edited (the
move dropped the executable bit of the four `.sh` scripts; it was restored on 2026-11-21), and
its scripts still work from this folder because they find their files relative to it:

```bash
cd alt/sergio_bram_design
python python/quantize_export.py --synthetic   # placeholder weights
./sim/run_sim.sh int8                          # TEST PASSED (Icarus or Xcelium)
fpga\build.bat int8 nexys4ddr                  # Vivado (Windows)
```
Setup notes for this version are in `SETUP.md` here (the original repo setup guide).

## How it differs from the main design

| | This version (`alt/sergio_bram_design`) | Main design (repo root) |
|---|---|---|
| Weights | On-chip synchronous ROMs (`kws_rom.v`), block-RAM friendly | External memory ports (ASIC); LUT ROMs on the FPGA |
| Input clip | Loaded into `in_buf` through `load_*` before `start` | Read from the input memory during the run |
| Requantize | `clamp(acc >>> SHIFT1, 0, QMAX)` (truncate) | `min((relu(acc) + 2^(SHIFT-1)) >> SHIFT, QMAX)` (round) |
| Accumulator | 32 bits | 23 bits (INT8) / 15 bits (INT4), sized so it cannot overflow |
| Words | yes, no, on, off, up, down | yes, no, on, off, left, right |
| Precisions | INT8, INT6, INT4 | INT8, INT4 |
| Training | NumPy only (no PyTorch), unit tests | PyTorch, QAT; trained on the real dataset |
| Weights status | synthetic (real training not run yet) | real model: 86.7 % (INT8), 85.1 % (INT4) |
| ASIC flow | Genus + Innovus, gpdk045 (paths not set yet) | RTL Compiler + Innovus, tsmc18 – finished, DRC clean |
| FPGA | 16 clips, 4 switches, one precision per bitstream | 200 clips, both precisions in one bitstream, run-all check |

The final report (`docs/report/`) describes the main design. Ideas from this version that are
worth carrying over later: the block-RAM weight ROMs (would let the FPGA run at 100 MHz), the INT6
data point, the NumPy-only training, and the unit tests.
