# Low-Precision Hardware Accelerator for Voice Keyword Recognition

EE 5113 VLSI System Design: final project (UTSA). It is a small neural-network accelerator
that recognizes 6 spoken words (**yes, no, on, off, left, right**). It is built at **INT8** and **INT4**
precision so the two can be compared on area, power, timing and accuracy, using:

- **Python**: Google Speech Commands → MFCC → small FC network → INT8/INT4 quantization (QAT)
- **Verilog**: one shared MAC, ReLU + shift requantize, argmax, control FSM (`rtl/`), bit-exact with Python
- **Cadence RTL Compiler + Innovus**: TSMC 180 nm (tsmc18) synthesis and place & route on `crosby3.utsarr.net`
- **Xilinx Vivado**: simulation, and a live demo on a Digilent **Nexys 4 / Nexys 4 DDR / Nexys A7** (Artix-7)

> **New machine or new partner? Start with [`docs/SETUP.md`](docs/SETUP.md).**
> For the latest status, read the newest file in [`docs/progress/`](docs/progress/).
> The final report is in [`docs/report/`](docs/report/).

## Architecture

```
  input mem  ──x_data──►┐
                        ├─► MUX ──► MAC (w × act + ACC) ──► ACC ──┬──► ReLU + round + >>SHIFT ──► hid_buf[32]
  hid_buf[32] ─────────►┘              ▲                          └──► argmax ──► class_out, done
  weight mem ──w_data──────────────────┘
  bias mem   ──b_data──► ACC (loaded at the start of each neuron)
  (FSM: IDLE → BIAS → MAC × N → POST → … → DONE; addresses are simple counters)
```

- Layer 1 is 250 inputs → 32 hidden, with ReLU and a round-half-up power-of-two requantize.
- Layer 2 is 32 → 6 scores, followed by argmax (ties → lowest index, like numpy).
- One clip takes **8,270 cycles** (82.7 µs at 100 MHz).
- The ASIC keeps the weights (8 KB / 4 KB), biases and inputs in external memory; the FPGA demo puts them
  in ROMs (`fpga/kws_fpga_core.v`).

## Results (tsmc18, slow corner, 100 MHz)

| | INT8 | INT4 | INT4 vs INT8 |
|---|---|---|---|
| Test accuracy (2,430 clips; hardware = Python) | 86.7 % | 85.1 % | −1.5 points |
| Chip area after routing | 79,401 µm² | 46,802 µm² | −41 % |
| Power after routing | 3.84 mW | 1.92 mW | −50 % |
| Max clock (core, synthesis) | 268 MHz | 315 MHz | +18 % |
| Setup slack @ 100 MHz / DRC | +0.079 ns / clean | +0.228 ns / clean | |

Details: [`results/RESULTS.md`](results/RESULTS.md). Reports: `results/int8/`, `results/int4/`, `results/fpga/`.

## Repository map

| Path | Contents |
|------|----------|
| `python/` | `train.py` (FP32 + PTQ/QAT), `quant.py` (**bit-exact golden model**), `export_hw.py`, `prepare_data.py`, `mfcc.py` |
| `weights/<int8,int4>/` | Generated: `weights.mem`, `biases.mem`, test clips and expected values, `kws_params.vh` |
| `rtl/` | `kws_accel.v` (core), `kws_top.v` (`kws_int8`, `kws_int4` chip tops) |
| `tb/`, `sim/` | Self-checking testbenches; `sim/run_sim.ps1` (Windows) / `sim/run_sim.sh`; `sim/vivado/` GUI project |
| `flow/tsmc18/` | RTL Compiler + Innovus scripts, constraints, pin files, `RUN_GUIDE.md`, `results.sh`, `save_results.sh` |
| `fpga/` | Board top with bit-exact self-check, ROM files, UART link (`uart.v`, `kws_uart_link.v`), `kws_live.py` (live words / self-test from a PC), Nexys 4 / 4 DDR pins, `build.tcl` / `program.tcl` (+ `.bat` / `.sh`) |
| `results/` | Curated reports (ASIC `int8/`, `int4/`; `fpga/` incl. bitstreams; `python/` accuracy, models, figures) |
| `docs/` | `SETUP.md`, `progress/` milestone logs, `report/` (final report + screenshots), `slides/`, `reference/` |
| `alt/sergio_bram_design/` | The other version of the design (on-chip ROMs, Genus/gpdk045 flow), kept intact |
| `CLAUDE.md` | Instructions Claude follows on every machine |

## Quick commands

```bash
.\sim\run_sim.ps1 int8                             # Windows + Vivado: RTL vs Python → TEST PASSED (also int4)
./sim/run_sim.sh int8                              # Linux/crosby3 (xsim, Xcelium or Icarus)
./sim/run_sim.sh fpga                              # board-level test of the FPGA top
python python/train.py && python python/export_hw.py && python fpga/gen_fpga_mem.py && python python/export_frontend.py   # retrain + re-export everything (needs the dataset)
cd flow/tsmc18 && rc -f syn_int8.g && innovus -files pnr_int8.tcl   # crosby3 (see RUN_GUIDE.md)
fpga\build.bat nexys4ddr program                   # Windows: build (~25 min) and load it (nexys4ddr | nexys4 | nexys_a7_50t)
fpga\program.bat nexys4ddr                         # Windows: load the last good build again
python fpga/kws_live.py --selftest                 # board == Python over the USB-UART (200 clips, INT8 + INT4)
python fpga/kws_live.py --mic                      # live words: say yes/no/on/off/left/right
python sim/uart_xcheck.py                          # no board: kws_live.py packets through the Verilog design (Icarus)
```

## Status

| Item | Status |
|------|--------|
| Repo, docs, collaboration workflow | ✅ done |
| Model trained on Speech Commands, INT8/INT4 QAT export | ✅ 86.7 % / 85.1 % |
| RTL + testbench (bit-exact vs Python, every layer, 200 real clips) | ✅ 0 mismatches, INT8 & INT4 |
| Synthesis + place & route (tsmc18), DRC/connectivity/antenna | ✅ both precisions, timing met at 100 MHz |
| FPGA demo (both precisions, 200 clips) | ✅ simulated; ✅ Nexys 4 DDR/A7 bitstream built (50 MHz, WNS +2.8 ns), before the self-check below |
| FPGA bit-exact self-check (PASS / FAIL / Err, SW14 fault test) | ✅ simulated; ⏳ rebuild from `sergio/board-check-live-voice` and test on the board |
| Live words from a microphone (USB-UART + `fpga/kws_live.py`) | ✅ simulated, cross-checked with Python; ⏳ on the board |
| Final report and slides | ✅ `docs/report/` ; 🟡 slides: 14-slide mock in the course's order, board results still placeholders (`docs/slides/`) |
| Optional: INT6, gpdk045 flow, block-RAM ROMs (see `alt/`) | ⏳ |

## Progress log

| Date | Milestone |
|------|-----------|
| 2026-11-18 | [Repository and environment set up](docs/progress/2026-11-18-repo-setup.md) |
| 2026-11-19 | [Testbench upgrade, INT6 export, NumPy training pipeline](docs/progress/2026-11-19-numpy-training-pipeline.md) (now in `alt/`) |
| 2026-11-19 | [Combined repo: trained model, tsmc18 ASIC results, FPGA demo, report](docs/progress/2026-11-19-combined-design.md) |
| 2026-11-20 | [Design comparison, review notes, board self-check, live words](docs/progress/2026-11-20-design-comparison-board-check.md) |
| 2026-11-20 | [Presentation deck: mock with placeholders, sources of every number](docs/progress/2026-11-20-slides-draft.md) |
| 2026-11-21 | [Handoff: continue on the Windows PC (xsim, board test, live words, slides)](docs/progress/2026-11-21-handoff-windows.md) |
