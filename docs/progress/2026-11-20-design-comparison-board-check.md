# Design comparison, review notes, board self-check and live words

- **Date:** 2026-11-20
- **Author:** sarreola07
- **Branch:** `sergio/board-check-live-voice` (pull request into `main`, draft until tested on the board)
- **Machine(s):** cloud Linux session (simulation, Python). Next: the Windows PC with Vivado and the Nexys board.


> **Status, 2026-11-21:** this log describes branch `sergio/board-check-live-voice` (PR #1). Its FPGA design
> (the BTNU score self-check, `kws_uart_link.v`, `kws_live.py`) was **not merged**. `main` uses chit2000's
> hardware-tested design from PR #2 (`docs/progress/2026-11-20-fpga-microphone.md`). The files this log names
> for that design exist only on the branch. Still valid for `main`: the comparison with `alt/` and the review
> notes. The repo fixes, the build timing check and the docs were carried over to `main` on 2026-11-21.

## Why
- The repo now holds two designs.
  - `main` is chit2000's finished design: PyTorch QAT, real weights, tsmc18 ASIC flow, FPGA demo.
  - `alt/sergio_bram_design/` is the earlier on-chip-ROM version.
- This branch does three things:
  - compares the two designs and lists review notes;
  - fixes repo problems;
  - adds a way to **check the FPGA board** with a bit-exact PASS/FAIL self-test and with **live words from a microphone**.

## The two designs side by side
All numbers are quoted from files in the repo.

| | `main` (chit2000) | `alt/sergio_bram_design` (sarreola07) |
|---|---|---|
| Words | yes, no, on, off, left, right | yes, no, on, off, up, down |
| MFCC | 40 ms Hamming frames, no overlap, 1024-pt FFT, 40 mels 20–7600 Hz, ln, DCT → 25×10 = 250 (`python/config.py`, `mfcc.py`) | 25 ms Hann frames, 10 ms hop, 40 mels, dB with an 80 dB floor, DCT, pooled 101 → 25 frames = 250 |
| Training | PyTorch, then PTQ and QAT per bit width (`python/train.py`) | NumPy MLP, PTQ only; never run on the real dataset |
| Requantize | round-half-up shift; accumulator 23 bits (INT8) / 15 bits (INT4) | truncating shift; 32-bit accumulator |
| Test accuracy (2,430 clips) | FP32 85.97 %, **INT8-QAT 86.67 %**, **INT4-QAT 85.14 %** (`results/python/results.csv`) | synthetic weights only |
| RTL | one module `rtl/kws_accel.v`, one MAC, same-cycle memory reads, 8,270 cycles per inference | mac / fc_layer / relu / argmax, synchronous (block-RAM style) ROMs, 8,312 cycles + 250-cycle load |
| Verification | every hidden value, score and class of 200 real clips vs Python (`tb/tb_kws.v`): 0 mismatches | final class of 50 clips, watchdog, X checks, one-inference VCD, 15 unit tests |
| ASIC | tsmc18, routed and DRC clean: 79,401 / 46,802 µm², 3.843 / 1.919 mW, setup slack +0.079 / +0.228 ns at 100 MHz (`results/RESULTS.md`) | gpdk045 scripts, never run |
| FPGA | both precisions, 200 clips, 50 MHz; 12,891 LUTs, 602 FFs, 0 BRAM, WNS +2.796 ns (`results/fpga/nexys4ddr/`) | 16 clips, never built |

**Worth carrying over from `alt/` later** (not done here):
- INT6 as an extra data point;
- unit tests plus GitHub CI;
- the one-inference VCD idea, for activity-based power;
- synchronous, block-RAM-friendly memories.

## Review notes for `main` (for chit2000)
1. **Fmax.** "INT4 runs ~18 % faster" (`results/RESULTS.md`) comes from separate 2 ns synthesis-only runs with zero I/O
   delay. The routed designs were only timed at 10 ns. Say how the number was measured, or measure Fmax after layout.
2. **Power.** It is vectorless: the reports say "Activity File: N.A." and use a default activity of 0.2. The weight and
   input memories are outside the core, so their area and power are not counted, and that is where INT4 halves the bits.
3. **Same-cycle memory reads.** No SRAM or block RAM can serve the core, which is why the FPGA needs LUT ROMs and 50 MHz.
4. **Corners and tests.** Hold is checked only at the slow corner. There is no gate-level simulation; `tb_kws.v` reads
   internal signals, so it can't run on the netlist.
5. **Latent bug.** `SHIFT = 0` would break `ROUND = 1 << (SHIFT-1)` in `rtl/kws_accel.v`, and `choose_shift` in
   `python/quant.py` can return 0. Today SHIFT is 9 and 5.
6. **Report** (`docs/report/`):
   - the cover says "Student Name: ____";
   - it is written as one author and never mentions the partner, `alt/` or INT6;
   - §3.6 says the microphone demo was not done; this branch adds one, still to be tested on a board;
   - the appendix cites paths and GDS files that are not in the repo;
   - `docs/slides/` is empty.
7. **Process.** The 2026-11-19 log promised a pull request, but the commits went straight to `main`. This branch uses a PR.

## What this branch adds
1. **Repo fixes** (`repo:` commit):
   - all 8 `.sh` scripts were mode 100644, so `./sim/run_sim.sh` failed on Linux/crosby3; now 100755;
   - `.gitignore` ignores `python/data/` and `python/checkpoints/` at any depth;
   - a stray backspace byte removed;
   - the alt README note corrected.
2. **Bit-exact board self-check** (`fpga:` commit):
   - `rtl/kws_accel.v` gets read-only observation ports (`dbg_*`, unconnected in the ASIC tops, no logic change).
   - Every class AND all 6 output scores are compared with Python on the board.
   - BTNU shows `PASS 176`, `F<first failing clip> <matches>`, or `Err ----`. Err means the checksum of the golden data
     is wrong, i.e. a missing or damaged `.mem` file, which used to give a false PASS.
   - SW14 is a fault test: it corrupts clip 0, so the board must fail there.
   - RGB LED16: green, red or blue.
   - A result is cleared when SW15 moves.
   - `build.tcl` refuses a bitstream that fails setup or hold timing: nothing is copied to `results/fpga`, and
     `build.bat <board> program` does not load the board.
   - `gen_fpga_mem.py --check` reports when `fpga/mem` is out of date.
3. **Live words over the USB-UART** (`fpga, python:` commit):
   - `fpga/uart.v` and `fpga/kws_uart_link.v` (115200 baud, packet protocol in the file header);
   - `fpga/kws_live.py` with `--selftest`, `--mic`, `--wav` and `--mock`;
   - `python/export_frontend.py` writes `weights/frontend.npz`, the training mean/std and input scales. They existed only in
     the git-ignored `features.npz` before.
4. **Review fixes and a UART cross-check** (`fpga, python, docs:` commit): see the next section.
   `sim/uart_xcheck.py` + `tb/tb_uart_xcheck.v` run the packets `kws_live.py` makes through the Verilog board design.

## Review before the PR
The whole branch was reviewed for bugs (RTL, Python, docs), and a second pass tried to disprove each finding before it
was accepted. These were confirmed, and all are fixed in the last commit:

| Where | Problem | Fix |
|---|---|---|
| `fpga/build.bat` | No error check after Vivado, so `build.bat <board> program` loaded the **old** bitstream after a failed build | Stops with "Build FAILED - the board was NOT programmed" |
| `fpga/build.tcl` | The reports were written to `results/fpga/` before the timing check, so a failed build left reports that don't belong to the committed bitstream; the message always said "50 MHz" | Reports go to `fpga/work/<board>/` and are copied together with the bitstream only when timing is met |
| `fpga/kws_fpga_top.v`, `tb/tb_fpga_top.v` | A register (`last_cls`) and test arrays were used before their declaration. Icarus accepted it, but the Verilog standard doesn't allow it, and a strict parser (slang) rejected it with 3 errors | Declared before use; slang: 0 errors |
| same | The score widths 23 and 15 were typed in several places | `ACC8` / `ACC4` localparams (CLAUDE.md rule updated) |
| `fpga/kws_uart_link.v` | A reply that became ready while the previous one was still going out was dropped | A one-entry pending slot; the new test 7e (two pings back to back) fails on the old code and passes now |
| `python/live_frontend.py`, `fpga/kws_live.py` | `frontend.npz` was checked against only 7 of the 9 MFCC settings, and not against the words or the model's input scale `s_x` | All 9 settings, the words and `s_x` are checked; a stale file stops the script and says what to run |
| docs | The `Err` text claimed it catches any missing `.mem` file; the retrain commands skipped `gen_fpga_mem.py` and `export_frontend.py`; README pointed at the old prebuilt bitstream; the Python ↔ Verilog cross-check had no committed command | Reworded (what `Err`, `F000   0` and a stale `fpga/mem` look like), commands fixed, `sim/uart_xcheck.py` added |

## Verification done in the cloud session (Icarus Verilog + Python)
All on the cloud Linux session, after the review fixes. The `./sim/run_sim.sh` commands also run on crosby3 (xsim or
Xcelium, drop `iverilog`) and on Windows (`.\sim\run_sim.ps1 <target>`).

| Check | Command | Result |
|---|---|---|
| RTL vs Python, every layer, after adding the observation ports | `./sim/run_sim.sh int8 iverilog`, then `int4` | 0 mismatches: 6,400 hidden values, 1,200 scores, 200 classes each |
| Board top: BTNC clip 2 | `./sim/run_sim.sh fpga iverilog` (about 60 s; every `tb_fpga_top` row is this one run) | `  2 LEFt`, class 4 = Python, all 6 scores equal |
| Board top: BTNU INT8 / INT4 | (same run) | `PASS 176` / `PASS 177` |
| Board top: SW15 flipped | (same run) | result cleared |
| Board top: SW14 fault test | (same run) | `F000 199` |
| Board top: damaged checksum | (same run) | `Err ----` |
| UART live packets (INT8 clips 2, 77; INT4 clips 2, 199) | (same run) | class and all 6 scores = Python, 8,271 cycles |
| UART bad checksum / ping / half packet | (same run) | status 1 and no run / status 2 / dropped, next packet OK |
| UART two pings back to back (test 7e) | (same run) | two pongs; with the old `kws_uart_link.v` the second never comes |
| `kws_live.py` packets → Verilog board → `kws_live.py` decoder | `python sim/uart_xcheck.py --wav python/data/speech_commands/left/00176480_nohash_0.wav` | 8/8 replies = Python (test clips 2, 77, 199 and the .wav, INT8 and INT4) |
| Live front end on the 200 test .wav files | `python python/export_frontend.py --verify` (needs the dataset) | 50,000/50,000 inputs identical to `test_inputs.mem`, INT8 and INT4 |
| `kws_live.py` with a software board | `python fpga/kws_live.py --mock --selftest` | 200/200 clips identical; 176/200 (INT8) and 177/200 (INT4) words correct |
| `fpga/mem` up to date | `python fpga/gen_fpga_mem.py --check` | `fpga/mem matches weights/` |
| Strict parse of the board design and both testbenches | slang (`pip install pyslang`), not committed | 0 errors (the previous commit: 3) |
| `build.tcl` timing gate | `tclsh` with stub Vivado commands, not committed | timing met: bitstream and reports copied; setup or hold failure: nothing copied, exit 1 |

The dataset was streamed in this session with `python python/prepare_data.py`: 18,470 / 2,254 / 2,430 clips, the same
counts as `results/python/logs/prepare_data.txt`.

## Files added or changed
| File | What | Used by |
|---|---|---|
| `rtl/kws_accel.v` | read-only `dbg_*` output ports, no logic change | simulation, FPGA; the ASIC tops leave them open |
| `rtl/kws_top.v` | `dbg_*` ports left unconnected | tsmc18 flow on crosby3 |
| `fpga/kws_fpga_core.v`, `fpga/kws_fpga_top.v` | score compare, checksums, verdict display, RGB LED16, SW14, live-input RAM and mux | Vivado (`fpga/build.tcl`), `sim/run_sim.* fpga` |
| `fpga/uart.v`, `fpga/kws_uart_link.v` | 115200 8N1 UART and the packet protocol (file header) | same |
| `fpga/gen_fpga_mem.py` → `fpga/mem/*.mem` | adds `<p>_logits8.mem` and `<p>_check.mem`; `--check` | Vivado and the simulations load them by name |
| `fpga/constraints/nexys4.xdc`, `nexys4ddr.xdc` | SW14, RGB LED16, UART pins | Vivado |
| `fpga/build.tcl`, `fpga/build.bat` | timing gate; results only with a good build; no programming after a failure | Windows PC with Vivado |
| `fpga/kws_live.py`, `fpga/requirements-live.txt` | PC side: `--selftest`, `--mic`, `--wav`, `--mock` | the PC the board is plugged into |
| `python/live_frontend.py`, `python/export_frontend.py` → `weights/frontend.npz` | live audio → hardware inputs, exactly like training | read by `kws_live.py` |
| `tb/tb_fpga_top.v` | board-level test, scenarios 1 to 7e | `sim/run_sim.* fpga` |
| `tb/tb_uart_xcheck.v`, `sim/uart_xcheck.py` | `kws_live.py` against the Verilog design | Linux, crosby3 or macOS with Icarus Verilog |
| `sim/run_sim.sh`, `sim/run_sim.ps1` | the UART files added to the fpga target | Linux / Windows |
| `docs/SETUP.md`, `README.md`, `CLAUDE.md`, this log | steps, commands, rules | both partners |
| all `*.sh`, `.gitignore`, `docs/progress/2026-11-19-combined-design.md`, `alt/sergio_bram_design/README.md` | repo fixes (`repo:` commit) | |

## How to test on the board (Windows PC + Vivado + Nexys)
The committed bitstream in `results/fpga/` is from **before** this branch, so it must be rebuilt.

```bat
git fetch
git switch sergio/board-check-live-voice
fpga\build.bat <board> program
```
- `<board>`: `nexys4` (plain Nexys 4), `nexys4ddr` (Nexys 4 DDR or Nexys A7-100T) or `nexys_a7_50t` (Nexys A7-50T).
- The build takes about 25 minutes. If timing fails, it stops with an error, copies nothing to `results/fpga` and
  does not program the board.

| Step | Expected |
|---|---|
| SW15 down, BTNU | green LED16, `PASS 176` |
| SW15 up, BTNU | green LED16, `PASS 177` |
| SW14 up, SW15 down, BTNU (then SW14 down) | red LED16, `F000 199` |
| `pip install -r fpga/requirements-live.txt`, then `python fpga/kws_live.py --selftest` | `SELFTEST PASSED`, 200/200 for INT8 and INT4 |
| `python fpga/kws_live.py --mic` | the board shows `LI <word>`, and the PC prints `board == Python` |

Then commit the new `results/fpga/` (bitstream and reports), write down what the board showed in a progress log, and
take the PR out of draft.

## Not verified yet (needs the board)
- **The Vivado build and timing.**
  - The live-input multiplexer adds a level to the 50 MHz critical path (old WNS +2.796 ns).
  - If **setup** timing fails (WNS < 0), lower the MMCM to 40 MHz: `CLKOUT0_DIVIDE_F` 25.0 in `fpga/kws_fpga_top.v`
    (VCO 1000 MHz / 25), and `UART_CLKS_PER_BIT` 347 (40 MHz / 115200). A slower clock does not fix a **hold**
    failure (WHS < 0); for that, look at the failing paths in `fpga/work/<board>/timing_summary.rpt`.
- The board's displays and LEDs, and the UART on real hardware.
- **Live microphone accuracy.** Expect it to be lower than the 86.7 % test accuracy, because the microphone, the room and
  the word's position in the 1-second window all differ from the dataset. No number until it is measured.

## Next steps
- [ ] Build, program and run the steps above; record what the board shows.
- [ ] Slides (about 10 minutes, 10–12 slides) after the board test.
- [ ] chit2000: review this PR and the notes above; add the student names to the report.
- [ ] Optional: activity-based power from a one-inference VCD, INT6, GitHub CI.
