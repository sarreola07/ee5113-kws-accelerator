# KWS accelerator – final results (INT8 vs INT4)

All numbers come from the reports in `results/int8/` and `results/int4/`
(tsmc18 180 nm library, slow corner, 1.62 V, 100 MHz clock). Run on crosby3, 2026-11-19.

## Comparison table

| Metric | INT8 | INT4 | INT4 vs INT8 |
|---|---|---|---|
| Weight memory | 8192 B | 4096 B | −50 % |
| Test accuracy (Python = hardware, bit-exact) | 86.67 % | 85.14 % | −1.5 points |
| Cycles per inference | 8270 | 8270 | same |
| **Synthesis (RC)** | | | |
| Cells | 1264 | 692 | −45.3 % |
| Flip-flops | 314 | 170 | −45.9 % |
| Cell area | 37,908 µm² | 20,700 µm² | −45.4 % |
| Power | 5.190 mW | 2.327 mW | −55.2 % |
| Critical path (speed-pushed run) | 3.73 ns | 3.17 ns | |
| Max clock Fmax (core) | 268 MHz | 315 MHz | +17.5 % |
| **Layout (Innovus, after routing)** | | | |
| Std-cell area (no fillers) | 38,673 µm² | 20,863 µm² | −46.1 % |
| Core area | 63,242 µm² | 34,608 µm² | |
| Chip area | 79,401 µm² | 46,802 µm² | −41.1 % |
| Core density | 61.2 % | 60.3 % | |
| Total wire length | 58,103 µm | 28,585 µm | −50.8 % |
| Worst setup slack @ 100 MHz | +0.079 ns | +0.228 ns | both meet timing |
| Max cap / tran / fanout violations | 0 | 0 | |
| Total power | 3.843 mW | 1.919 mW | −50.1 % |
| Energy per inference (power × 82.7 µs) | 317.8 nJ | 158.7 nJ | −50.1 % |
| DRC / connectivity / antenna | clean | clean | |

**Conclusion:** INT4 halves the power and energy, takes about 41 % less chip area and runs about 18 % faster,
for a 1.5-point drop in accuracy (86.7 % → 85.1 %).

## Screenshots (`docs/report/screenshots/`)

| File | Shows |
|---|---|
| `vivado/01…06` | Vivado simulation: INT8/INT4 PASS consoles, full-inference waveform, argmax + done, MAC cycles |
| `synthesis/S1_int8_rc_synthesis_done.png`, `S6_int4_…` | RTL Compiler finishing ("Synthesis succeeded") |
| `innovus/I1_int8_final_layout.png`, `I1_int4_final_layout.png` | Final routed chips |
| `innovus/I2_int8_placement_cells.png` | Placed standard cells |
| `innovus/I3_int8_power_grid.png` | Power ring, Metal4 stripes, Metal1 rails |
| `innovus/I4_int8_zoom_cells_wires.png` | Close-up: named cells, rails, metal layers |
| `innovus/I5_int8_clock_tree.png` | Routed clock tree |
| `innovus/I6_int8_postroute_timing_summary.png` | Post-route timing: WNS +0.079 ns, 0 violations |
| `innovus/I7_int8_drc_power_area.png` | INT8 DRC/connectivity/antenna clean, power, area |
| `innovus/I8_int4_timing_drc_power_area.png` | INT4 timing, DRC, power, area |
| `innovus/stages/int8_1…6`, `int4_1…6` | Pictures saved by the script at each step: floorplan, power grid, placement, CTS, routed, final |
| `R1_results_table_int8_vs_int4.png` | `results.sh` comparison table |

## Two fixes needed on the server (already in the scripts)

1. **MMMC order** – Innovus 20.1 read `slow.lib` before the LEF when it was given as
   `init_mmmc_file`, kept 0 cells, and CTS then found no clock buffers. The flow now runs
   `init_design` first and then `source`s the MMMC file (the same order as HW7).
2. **No scan flip-flops** – RC used scan flops (SDFF) as cheap enable flops (68 % of all flops),
   and Innovus stopped placement with IMPSP-9099 ("scan chains exist but are not defined").
   Synthesis now marks `SDFF*`/`SEDFF*` as `avoid`. The design has no scan chain anyway.

## FPGA (Vivado 2024.2, Artix-7 xc7a100tcsg324-1)

Both chips (INT8 and INT4) in one bitstream, weights and the 200 test clips in distributed (LUT) ROMs,
50 MHz clock from an MMCM. The board runs a power-on self-test (all 200 clips on both precisions) and is
then driven by the switches, or by words from the PC microphone (`fpga/mic_demo.py` sends each word's
INT8 and INT4 inputs over the USB-UART); see the README for the controls.

| Metric | Nexys 4 (`nexys4`) | Nexys 4 DDR / A7-100T (`nexys4ddr`, with microphone input) |
|--------|--------------------|-------------------------------------|
| Bitstream | `results/fpga/kws_fpga_top_nexys4.bit` | `results/fpga/kws_fpga_top_nexys4ddr.bit` |
| Slice LUTs | 13,357 of 63,400 (21.1 %) | 13,762 (21.7 %), 82 of them LUT RAM |
| Slice registers | 928 (0.7 %) | 1,431 (1.1 %) |
| Block RAM / DSP / MMCM | 0 / 0 / 1 | 0 / 0 / 1 |
| Setup WNS / hold WHS at 50 MHz | +2.653 ns / +0.121 ns | +1.116 ns / +0.095 ns |
| One clip | 8,270 cycles = 165 µs | same |
| Board-level simulation | self-test 176/200 (INT8), 177/200 (INT4), 400/400 same as Python | same, plus words sent from the PC |
| On the board (Nexys A7-100T) | | self-test PASS; `fpga/mic_demo.py --clips`: the 200 clips sent from the PC over the UART give INT8 176/200, INT4 177/200, 400/400 same as Python; 12/12 text-to-speech words right |

Reports: `results/fpga/<board>/timing_summary.rpt`, `utilization.rpt`.
