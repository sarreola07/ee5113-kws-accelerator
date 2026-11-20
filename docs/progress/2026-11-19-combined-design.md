# Combined repo: trained model, tsmc18 ASIC results, FPGA demo and final report

- **Date:** 2026-11-19
- **Author:** chit2000
- **Branch / commit:** `combine-designs` (merge into `main` with a pull request)
- **Machine(s):** Windows laptop with Vivado 2024.2 (Python, simulation, FPGA build); crosby3 (RTL Compiler + Innovus)

## What was done
- **Combined the two versions of the project.** The finished, verified flow is now the main design at the
  repo root. The previous version (on-chip ROMs, Genus/gpdk045 flow, NumPy training, INT6) moved unchanged
  to `alt/sergio_bram_design/` with its git history; its scripts still run from there. Kept from it: the
  repo layout, `docs/SETUP.md`, the progress-log process, `CLAUDE.md` rules, `.gitignore`/`.gitattributes`,
  the `results/` convention and the multi-board FPGA scripts (`build.bat`/`build.sh`, nexys4/nexys4ddr).
- **Model:** 250→32→6 network for yes/no/on/off/left/right, trained in PyTorch on Speech Commands v0.02,
  INT8 and INT4 by QAT. Bit-exact integer golden model in `python/quant.py`. Exported to `weights/`.
- **RTL:** `rtl/kws_accel.v` (one shared MAC, round-half-up shift requantize, argmax, 5-state FSM, memories
  outside the core) and `rtl/kws_top.v` (`kws_int8`, `kws_int4`). The testbench checks every hidden value,
  every output score and every class against Python on 200 real test clips.
- **ASIC (crosby3, tsmc18 slow corner):** RTL Compiler synthesis at 100 MHz, separate 2 ns runs for Fmax,
  Innovus place & route (same steps as HW7), DRC/connectivity/antenna clean for both precisions.
- **FPGA:** `fpga/kws_fpga_top.v` puts both chips on one Artix-7 with LUT ROMs holding the weights and all
  200 clips. BTNC runs one clip; BTNU runs all 200 and shows correct / matches-Python counts. Runs at
  50 MHz from an MMCM (at 100 MHz the routed WNS was −4.4 ns). Pins for Nexys 4 (original) and Nexys 4 DDR/A7.
- **Report:** `docs/report/EE5113_Final_Project_Report.docx` (+ PDF) and its screenshots.

## How to reproduce / load it
```bash
# where: Windows + Vivado (PowerShell, repo root)
git pull --rebase
.\sim\run_sim.ps1 int8        # -> 0 mismatches, 176/200 correct, TEST PASSED
.\sim\run_sim.ps1 int4        # -> 0 mismatches, 177/200 correct, TEST PASSED
.\sim\run_sim.ps1 fpga        # -> [176  200], [177  200], FPGA TOP TEST PASSED
fpga\program.bat nexys4ddr    # board plugged in (or nexys4 / nexys_a7_50t after fpga\build.bat <board>)
```
```bash
# where: crosby3 (after: source /home/opt2/setmyenv)
git pull --rebase
cd flow/tsmc18
cp ~/EE5113_Hw7/slow.lib ~/EE5113_Hw7/all.lef ~/EE5113_Hw7/gds2_innovus-2.map .   # not in git
rc -f syn_int8.g ; rc -f fmax_int8.g ; rc -f syn_int4.g ; rc -f fmax_int4.g
innovus -files pnr_int8.tcl      # type exit when done
innovus -files pnr_int4.tcl
bash results.sh
./save_results.sh int8 ; ./save_results.sh int4
```
```bash
# where: any laptop (only to retrain; downloads the dataset into python/data/)
pip install -r python/requirements.txt
python python/prepare_data.py && python python/train.py && python python/export_hw.py
python fpga/gen_fpga_mem.py
```

## Files added / changed
| File | What it is | Used by |
|------|-----------|---------|
| `python/*.py`, `python/requirements.txt` | Training, QAT, golden model, export (PyTorch) | laptop |
| `weights/int8`, `weights/int4` | Weights, biases, 200 test clips + expected values, `kws_params.vh` | `tb/tb_kws.v`, `fpga/gen_fpga_mem.py` |
| `rtl/kws_accel.v`, `rtl/kws_top.v` | Accelerator core and chip tops | sim, ASIC flow, FPGA |
| `tb/tb_kws.v`, `tb/tb_fpga_top.v` | Self-checking testbenches | `sim/run_sim.ps1`, `sim/run_sim.sh`, Vivado |
| `sim/run_sim.ps1`, `sim/run_sim.sh`, `sim/vivado/*` | Command-line and GUI simulation | Windows / Linux |
| `flow/tsmc18/*` | RC + Innovus scripts, SDC, pin files, `RUN_GUIDE.md`, `results.sh`, `save_results.sh` | crosby3 |
| `fpga/*` | Board top, ROM files, pins (nexys4, nexys4ddr), build/program scripts | Vivado |
| `results/int8`, `results/int4` | Curated RC and Innovus reports, timing summaries, layout pictures, netlists | report |
| `results/fpga/` | Prebuilt `kws_fpga_top_nexys4ddr.bit` + its timing/utilization reports (`nexys4ddr/`) | board |
| `results/python/` | Accuracy tables, confusion matrices, trained models, figures | report |
| `docs/report/` | Final report (.docx, .pdf) and screenshots | submission |
| `alt/sergio_bram_design/` | Previous version of the design, unchanged | reference |

## Results
| Metric | INT8 | INT4 |
|--------|------|------|
| Test accuracy (2,430 clips), Python = hardware | 86.67 % | 85.14 % |
| RTL sim: mismatches / correct on 200 clips | 0 / 176 | 0 / 177 |
| Synthesis: cells / cell area / power | 1,264 / 37,908 µm² / 5.19 mW | 692 / 20,700 µm² / 2.33 mW |
| Fmax (core, 2 ns run) | 268 MHz | 315 MHz |
| Layout: chip area / power @ 100 MHz | 79,401 µm² / 3.84 mW | 46,802 µm² / 1.92 mW |
| Layout: setup / hold WNS @ 100 MHz | +0.079 / +0.259 ns | +0.228 / +0.256 ns |
| DRC / connectivity / antenna | clean | clean |
| FPGA, Nexys 4 DDR / A7-100T (both in one bitstream, 50 MHz) | 12,891 LUTs (20.3 %), 602 FFs, 0 BRAM, 1 MMCM; WNS +2.796 ns, WHS +0.027 ns | |

## Problems hit & fixes
- Innovus 20.1 read `slow.lib` before the LEF when the MMMC file was given with `init_mmmc_file` ("Read 0
  cells"), so CTS found no buffers. Fix: `source` the MMMC file after `init_design` (as in HW7).
- RC used scan flip-flops for 68 % of the registers and Innovus stopped with IMPSP-9099. Fix: `avoid` on
  `SDFF*`/`SEDFF*` in `syn_flow.tcl`.
- RC area recovery makes the 100 MHz slack ~0, so Fmax is measured with a separate 2 ns synthesis.
- FPGA at 100 MHz failed timing (WNS −4.4 ns: LUT ROM read + MAC in one cycle). Fix: 50 MHz MMCM clock.
- Windows paths with spaces break some Vivado options; see `CLAUDE.md` for the workarounds.
- `fpga/build.tcl` failed at the very end (after the bitstream was written) because Tcl `glob` returns a
  list, which `file copy` read as one braced path. Fix: `[lindex [glob ...] 0]`.

## Next steps
- [ ] Test `results/fpga/kws_fpga_top_nexys4ddr.bit` on the real board (BTNU should show `176  200` / `177  200`).
- [ ] Original Nexys 4 (no DDR): run `fpga\build.bat nexys4` once (~25 min) and commit `results/fpga/`.
- [ ] Slides (`docs/slides/`).
- [ ] Optional: INT6 with the main design; block-RAM ROMs (from `alt/`) to run the FPGA at 100 MHz;
      gpdk045 run to match the proposal's 45 nm plan.
