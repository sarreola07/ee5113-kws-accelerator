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

## FPGA board demo (Nexys 4 / Nexys 4 DDR / Nexys A7-100T)

Both precisions are in one bitstream, with the weights and the 200 test clips in on-chip ROMs.

```bat
REM Nexys 4 DDR or Nexys A7-100T (the team's board): loads results\fpga\kws_fpga_top_nexys4ddr.bit
fpga\program.bat nexys4ddr
REM original Nexys 4, no DDR: loads results\fpga\kws_fpga_top_nexys4.bit (built, not yet tried on that board)
fpga\program.bat nexys4
```

**Speak to it (no switches needed):** load the bitstream, leave all switches down, then on the PC run

```bat
REM once
python -m pip install numpy pyserial sounddevice
REM then say: yes, no, on, off, left, right
python fpga\mic_demo.py
```

The PC records each word, computes its MFCC inputs (INT8 and INT4, as in `python/`) and sends them over
the USB cable. The FPGA runs both accelerators and shows the word, e.g. `  3  YES` (3 = words heard so
far). The PC prints the FPGA's answer next to the Python model's (`same as Python`).
`python fpga\mic_demo.py --clips` sends the 200 test clips instead, using their stored inputs (so it skips the
microphone front end), and checks every answer of the board against Python.

| Control | What the board does |
|---------|---------------------|
| Power on / CPU_RESET | Self-test: all 200 clips on INT8 and INT4. The display shows `PASS` for 3 s and LED11 stays on (all 400 answers = Python). With all switches down it then shows ` rEAdY  ` |
| PC microphone (`fpga/mic_demo.py`) | Each word runs on INT8 and INT4: `  3  YES` (INT8 word; INT4 with SW15 up). LED10 = word from the PC, LED13 = both same as Python |
| SW7–SW0 | Clip number 0–199 in binary. With SW14 down the clip runs by itself: `  5  YES`, `  2 LEFt`, … |
| SW14 up | All 200 clips: `176  200` (INT8) / `177  200` (INT4) = words correct, answers same as Python |
| SW15 | Down = INT8, up = INT4 |
| LEDs | LED[2:0] word heard, LED[6:4] true word, LED12 correct, LED13 same as Python, LED14 busy, LED15 INT4 |
| USB-UART (115200 baud) | One text line per result: `powershell -ExecutionPolicy Bypass -File fpga\monitor.ps1` (or PuTTY). `mic_demo.py` uses the same port, so close the monitor first |

## Repository map

| Path | Contents |
|------|----------|
| `python/` | `train.py` (FP32 + PTQ/QAT), `quant.py` (**bit-exact golden model**), `export_hw.py`, `prepare_data.py`, `mfcc.py` |
| `weights/<int8,int4>/` | Generated: `weights.mem`, `biases.mem`, test clips and expected values, `kws_params.vh` |
| `rtl/` | `kws_accel.v` (core), `kws_top.v` (`kws_int8`, `kws_int4` chip tops) |
| `tb/`, `sim/` | Self-checking testbenches; `sim/run_sim.ps1` (Windows) / `sim/run_sim.sh`; `sim/vivado/` GUI project |
| `flow/tsmc18/` | RTL Compiler + Innovus scripts, constraints, pin files, `RUN_GUIDE.md`, `results.sh`, `save_results.sh` |
| `fpga/` | Board top, ROM files, Nexys 4 / 4 DDR pins, `build.tcl` / `program.tcl` (+ `.bat` / `.sh`), `mic_demo.py` (PC microphone → board) |
| `results/` | Curated reports (ASIC `int8/`, `int4/`; `fpga/` incl. bitstreams; `python/` accuracy, models, figures) |
| `docs/` | `SETUP.md`, `progress/` milestone logs, `report/` (final report + screenshots), `slides/`, `reference/` |
| `alt/sergio_bram_design/` | The other version of the design (on-chip ROMs, Genus/gpdk045 flow), kept intact |
| `CLAUDE.md` | Instructions Claude follows on every machine |

## Quick commands

```bash
.\sim\run_sim.ps1 int8                             # Windows + Vivado: RTL vs Python → TEST PASSED (also int4)
./sim/run_sim.sh int8                              # Linux/crosby3 (xsim, Xcelium or Icarus)
./sim/run_sim.sh fpga                              # board-level test of the FPGA top
python python/train.py && python python/export_hw.py   # retrain + re-export (needs the dataset)
cd flow/tsmc18 && rc -f syn_int8.g && innovus -files pnr_int8.tcl   # crosby3 (see RUN_GUIDE.md)
fpga\program.bat nexys4ddr                         # Windows: load the prebuilt bitstream (Nexys A7-100T / 4 DDR; nexys4 for the original Nexys 4)
python fpga\mic_demo.py                            # then speak: the board shows the word
fpga\build.bat nexys4ddr program                   # Windows: rebuild (~20 min) and load; stops if timing fails
```

## Status

| Item | Status |
|------|--------|
| Repo, docs, collaboration workflow | ✅ done |
| Model trained on Speech Commands, INT8/INT4 QAT export | ✅ 86.7 % / 85.1 % |
| RTL + testbench (bit-exact vs Python, every layer, 200 real clips) | ✅ 0 mismatches, INT8 & INT4 |
| Synthesis + place & route (tsmc18), DRC/connectivity/antenna | ✅ both precisions, timing met at 100 MHz |
| FPGA demo (switches, power-on self-test, UART report, PC microphone) | ✅ simulated; ✅ on a Nexys A7-100T: self-test PASS, 200 clips sent from the PC = Python (400/400); ✅ bitstreams for Nexys 4 DDR/A7 and Nexys 4, both with the microphone input (50 MHz, timing met; the Nexys 4 one not yet tried on a board) |
| Final report and slides | ✅ `docs/report/` ; ✅ slides: 14 slides, the source of every number in `docs/slides/README.md` (still to add: date, board photo) |
| Optional: INT6, gpdk045 flow, block-RAM ROMs (see `alt/`) | ⏳ |

## Progress log

| Date | Milestone |
|------|-----------|
| 2026-11-18 | [Repository and environment set up](docs/progress/2026-11-18-repo-setup.md) |
| 2026-11-19 | [Testbench upgrade, INT6 export, NumPy training pipeline](docs/progress/2026-11-19-numpy-training-pipeline.md) (now in `alt/`) |
| 2026-11-19 | [Combined repo: trained model, tsmc18 ASIC results, FPGA demo, report](docs/progress/2026-11-19-combined-design.md) |
| 2026-11-19 | [FPGA demo: switch control, power-on self-test, UART report, Nexys 4 build](docs/progress/2026-11-19-fpga-switch-selftest.md) |
| 2026-11-20 | [FPGA demo: words from the PC microphone, no switches needed](docs/progress/2026-11-20-fpga-microphone.md) |
| 2026-11-20 | [Design comparison and review notes (PR #1's alternative FPGA design, not merged)](docs/progress/2026-11-20-design-comparison-board-check.md) |
| 2026-11-20 | [Presentation deck: 14 slides, sources of every number](docs/progress/2026-11-20-slides-draft.md) |
| 2026-11-21 | [Handoff: continue on the Windows PC (Nexys A7-100T)](docs/progress/2026-11-21-handoff-windows.md) |
