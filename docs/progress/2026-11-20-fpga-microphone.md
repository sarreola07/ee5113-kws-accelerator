# FPGA demo: words from the PC microphone (no switches needed)

- **Date:** 2026-11-20
- **Author:** chit2000
- **Branch / commit:** `main`
- **Machine(s):** Windows laptop with Vivado 2024.2 and a microphone; Nexys A7-100T

## What was done
- The switch test from 2026-11-19 worked on the Nexys A7. Next step: say a word into the PC
  microphone and the board shows it, with all switches down.
- **Split of the work.** The project always did the front end (MFCC, normalization, quantization) in
  software, and the chip does the neural network. The same split is kept:
  - `fpga/mic_demo.py` (PC) records the microphone, finds each word (level above 3x the room noise),
    takes the loudest 1 s around it, scales it to the typical training loudness, then computes the
    250 MFCC inputs with `python/mfcc.py` and quantizes them to INT8 and INT4 with `python/quant.py`.
  - It sends one 504-byte packet over the board's USB-UART (115200 baud, 44 ms):
    `"K"`, Python INT8 class, Python INT4 class, 250 INT8 inputs, 250 INT4 inputs, checksum.
  - The FPGA (`fpga/kws_fpga_top.v`) receives it (new `uart_rx`) into two small LUT RAMs. It runs the
    INT8 and then the INT4 accelerator on them and shows the word, e.g. `  3  YES` (3 = words heard
    so far). It answers with one text line, e.g.
    `MIC 003: INT8 heard yes   (Python yes  ) | INT4 heard yes   (Python yes  ) -> same as Python`.
  - The Python classes in the packet are used only for that "same as Python" check (LED13). The FPGA
    computes its own answer from the inputs.
- `fpga/kws_fpga_core.v`: new `live` / `x_live` / `x_addr` ports. The input comes from the test-clip
  ROM or from the microphone word. `rtl/kws_accel.v` is unchanged.
- With all switches down, the display shows ` rEAdY  ` after the self-test, and nothing runs until a
  word arrives or a switch moves. The switch and button tests from 2026-11-19 work as before.
- New pin: `UART_RXD` on C4 (both boards). A packet with a wrong checksum is ignored and reported. A
  packet that stops half-way (50 ms pause) is dropped.
- `python/prepare_data.py` now also writes `results/python/feature_norm.npz` (feature mean/std and
  typical loudness, 3 KB, committed). It was made once from the existing `python/data/features.npz`.
  That file's test features quantize exactly to `weights/int*/test_inputs.mem`, so it is the
  normalization the model was trained with.
- `tb/tb_fpga_top.v`: new steps 8–12 (see below).

## How to reproduce / load it
```bat
:: where: Windows + Vivado (Command Prompt, repo root), board on USB-PROG/UART, all switches down
git pull --rebase
REM expect: FPGA TOP TEST PASSED
powershell -ExecutionPolicy Bypass -File sim\run_sim.ps1 fpga
REM Nexys 4 DDR / A7-100T (nexys4 for the original Nexys 4)
fpga\program.bat nexys4ddr
REM once
python -m pip install numpy pyserial sounddevice
REM no microphone: 200 test clips over the UART
python fpga\mic_demo.py --clips
REM speak: yes, no, on, off, left, right
python fpga\mic_demo.py
REM only to rebuild (~20 min, keep the laptop awake)
fpga\build.bat nexys4ddr
```

## Files added / changed
| File | What it is | Used by |
|------|-----------|---------|
| `fpga/mic_demo.py` | PC side: microphone → MFCC → INT8/INT4 → UART; prints the FPGA's and Python's answers | Windows / any PC with Python |
| `fpga/kws_fpga_top.v` | + `uart_rx`, packet receiver, microphone-word RAMs, `rEAdY` screen, `MIC` text line, LED10 | `fpga/build.tcl`, sim |
| `fpga/kws_fpga_core.v` | + `live`, `x_live`, `x_addr` ports | `kws_fpga_top.v` |
| `fpga/constraints/nexys4.xdc`, `nexys4ddr.xdc` | + `UART_RXD` on C4 | `fpga/build.tcl` |
| `tb/tb_fpga_top.v` | + steps 8–12: reset with switches down, two words from the "PC", bad checksum, switches again | `sim/run_sim.ps1 fpga` |
| `python/prepare_data.py`, `results/python/feature_norm.npz` | Normalization for live audio | `fpga/mic_demo.py` |
| `python/requirements.txt` | + pyserial, sounddevice (only for the microphone demo) | pip |
| `results/fpga/kws_fpga_top_nexys4ddr.bit`, `results/fpga/nexys4ddr/*.rpt` | Rebuilt with the microphone input | `fpga/program.bat nexys4ddr` |
| `results/fpga/kws_fpga_top_nexys4.bit`, `results/fpga/nexys4/*.rpt` | Same for the original Nexys 4 | `fpga/program.bat nexys4` |
| `README.md`, `docs/SETUP.md`, `CLAUDE.md`, `results/RESULTS.md`, `python/README.md` | How to use it | everyone |

## Results
| Check | Result |
|-------|--------|
| `run_sim.ps1 fpga` (steps 0–12) | FPGA TOP TEST PASSED; after a reset with switches down `rEAdY`; PC words "clip 5" → `  1  YES`, "clip 2" → `  2 LEFt`, both `-> same as Python`; bad checksum ignored |
| PC front end on Windows text-to-speech words (2 voices × 6 words) | 12/12 recognized by the Python integer model (with and without loudness scaling) |
| FPGA build (`nexys4`, original Nexys 4, 18 min) | 13,761 LUTs (21.7 %), 1,371 registers; WNS +0.673 ns / WHS +0.024 ns at 50 MHz (not tried on that board) |
| FPGA build (`nexys4ddr`, 18 min) | 13,762 LUTs (21.7 %, of which 82 LUT RAM), 1,431 registers, 0 BRAM / 0 DSP; WNS +1.116 ns / WHS +0.095 ns at 50 MHz |
| Board (Nexys A7-100T): self-test | `SELF-TEST PASS: INT8 176/200 correct, 200/200 same as Python; INT4 177/200 correct, 200/200 same as Python` |
| Board: `mic_demo.py --clips` | 200 clips sent from the PC in 13 s: INT8 176/200 correct, INT4 177/200, 400/400 same as Python -> PASS |
| Board: `mic_demo.py --wav` with the 12 text-to-speech words | 12/12 right on the FPGA, all `same as Python` |
| Board: live microphone | works: words spoken into the laptop microphone show on the display (checked by chit2000) |

## Problems hit & fixes
- Only one program can open the board's COM port: close PuTTY / `monitor.ps1` before `mic_demo.py`.
- The packet is 504 bytes (`"K"` + 2 + 250 + 250 + checksum); a first comment said 503.

## Next steps
- [ ] Photo / short video of a spoken word on the display for the report and slides.
- [x] Rebuild `kws_fpga_top_nexys4.bit` (original Nexys 4) with the microphone input (built; not tried on that board).
- [ ] Compare with `sergio/board-check-live-voice` (same features, other design) and pick one for `main`.
