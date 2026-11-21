# FPGA demo: switch control, power-on self-test, UART report, Nexys 4 build

- **Date:** 2026-11-19
- **Author:** chit2000
- **Branch / commit:** `main`
- **Machine(s):** Windows laptop with Vivado 2024.2 (simulation, both board builds, board test)

## What was done
- **Found why the board "did nothing":** the board on the lab laptop was an **original Nexys 4**
  (Vivado shows the cable as `jsn-Nexys4-…`), but the only bitstream was for the Nexys 4 DDR / A7, which
  has different pins. Built `results/fpga/kws_fpga_top_nexys4.bit` and rebuilt the Nexys 4 DDR / A7 one.
- **Test with switches and the 7-segment display only** (`fpga/kws_fpga_top.v`):
  - power-on self-test (also after CPU_RESET): all 200 clips on INT8, then on INT4. `PASS`/`FAIL` on the
    display for 3 s, LED11 stays on if all 400 answers are the same as Python;
  - **SW14 down:** the clip on SW7–SW0 runs by itself when the switches change (no button needed);
  - **SW14 up:** all 200 clips, totals on the display; flipping SW15 reruns for the other precision;
  - BTNC / BTNU still work.
- **UART text report** at 115200 baud on the board's USB-UART (pin D4 on both boards): one line per
  result, plus the self-test lines. `fpga/monitor.ps1` finds the Digilent COM port and prints them.
- `tb/tb_fpga_top.v` now follows the same steps as a person at the board (self-test, switches, buttons)
  and decodes the UART text. `sim/run_sim.ps1` also prints the step headers and the UART lines.

## How to reproduce / load it
```bat
:: where: Windows + Vivado (Command Prompt, repo root)
git pull --rebase
REM expect: FPGA TOP TEST PASSED
powershell -ExecutionPolicy Bypass -File sim\run_sim.ps1 fpga
REM original Nexys 4 (or nexys4ddr for Nexys 4 DDR / A7-100T)
fpga\program.bat nexys4
REM optional: the board's text report
powershell -ExecutionPolicy Bypass -File fpga\monitor.ps1
REM only to rebuild (~20 min; keep the laptop from sleeping)
fpga\build.bat nexys4
```

What the board shows:
1. `--------` during the self-test (well under a second), then `  PASS  ` for 3 s, and LED11 on.
2. SW14 down, SW15 down, SW7–SW0 = 00000101 → `  5  YES` (clip 5, INT8). 00000010 → `  2 LEFt`
   (clip 2 is "yes", but Python makes the same mistake: LED12 off, LED13 on).
3. SW14 up → `176  200` (INT8). Then SW15 up → `177  200` (INT4).

UART text (self-test):
```
=== EE5113 KWS accelerator: power-on self-test, 200 clips on INT8 then INT4 ===
INT8 all 200 clips: 176/200 correct, 200/200 same as Python -> PASS
INT4 all 200 clips: 177/200 correct, 200/200 same as Python -> PASS
SELF-TEST PASS: INT8 176/200 correct, 200/200 same as Python; INT4 177/200 correct, 200/200 same as Python
```

## Files added / changed
| File | What it is | Used by |
|------|-----------|---------|
| `fpga/kws_fpga_top.v` | Board top: self-test, switch-driven runs, PASS/FAIL, UART text report (`uart_tx`) | `fpga/build.tcl`, sim |
| `fpga/constraints/nexys4.xdc`, `nexys4ddr.xdc` | + SW14 (P3 / U11) and UART_TXD (D4) | `fpga/build.tcl` |
| `fpga/monitor.ps1` | Prints the board's UART text (finds the COM port itself) | Windows |
| `tb/tb_fpga_top.v` | Board-level test: self-test, switches, buttons, UART decode | `sim/run_sim.ps1 fpga` |
| `sim/run_sim.ps1` | Also prints the step headers and UART lines | Windows |
| `results/fpga/kws_fpga_top_nexys4.bit`, `results/fpga/nexys4/*.rpt` | Original Nexys 4 bitstream + reports | `fpga/program.bat nexys4` |
| `results/fpga/kws_fpga_top_nexys4ddr.bit`, `results/fpga/nexys4ddr/*.rpt` | Nexys 4 DDR / A7-100T bitstream + reports (rebuilt) | `fpga/program.bat nexys4ddr` |
| `README.md`, `docs/SETUP.md`, `CLAUDE.md`, `results/RESULTS.md` | New controls, expected results, board-variant note | everyone |

## Results
| Metric | Nexys 4 (`nexys4`) | Nexys 4 DDR / A7-100T (`nexys4ddr`) |
|--------|--------------------|-------------------------------------|
| Slice LUTs | 13,357 (21.1 %) | 13,357 (21.1 %) |
| Slice registers | 928 (0.7 %) | 928 (0.7 %) |
| Block RAM / DSP | 0 / 0 | 0 / 0 |
| Setup WNS / hold WHS at 50 MHz | +2.653 ns / +0.121 ns | +2.033 ns / +0.083 ns |
| Simulation (`run_sim.ps1 fpga`) | self-test INT8 176/200, INT4 177/200, 400/400 same as Python; all switch and button steps pass | same RTL |

## Problems hit & fixes
- Wrong board variant: a bitstream for another Nexys variant programs fine but nothing works (different
  pins). Check the label, or the `PARAM.DEVICE` property of the target in the Hardware Manager.
- The first Nexys 4 build took 4 hours: synthesis used 9 minutes of CPU, so the laptop went to sleep.
  Keep the laptop awake (plugged in, sleep off) during builds; a normal build is about 20 minutes.

## Next steps
- [ ] Photo of `PASS`, `176  200` and `177  200` on the board for the report.
- [ ] Slides (`docs/slides/`).
