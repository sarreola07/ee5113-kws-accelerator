# tsmc18 ASIC flow – Run Guide (RTL Compiler + Innovus on crosby3)
**Low-Precision Hardware Accelerator for Voice Keyword Recognition (INT8 vs INT4)**

The same Verilog design is built twice: `kws_int8` (8-bit) and `kws_int4` (4-bit).
Each one goes through: Vivado simulation → synthesis (RC) → place & route (Innovus).

---

## 0. What is in this folder (`flow/tsmc18/`)

| File | What it is |
|---|---|
| `../../rtl/kws_accel.v`, `../../rtl/kws_top.v` | The RTL that gets synthesized (read straight from the repo's `rtl/`) |
| `kws.sdc` | Timing constraints: 100 MHz clock (used for synthesis + Innovus) |
| `kws_fast.sdc` | 2 ns clock, only to measure the maximum frequency (Fmax) |
| `syn_flow.tcl` + `syn_int8.g`, `syn_int4.g` | Synthesis at 100 MHz → netlist for Innovus |
| `fmax_int8.g`, `fmax_int4.g` | Speed-pushed synthesis → Fmax |
| `pnr_flow.tcl` + `pnr_int8.tcl`, `pnr_int4.tcl` | Innovus flow (same steps as the HW7 MAF flow) |
| `kws_int8.io`, `kws_int4.io` | Pin placement for Innovus |
| `results.sh` | Prints the INT8 vs INT4 comparison table |
| `save_results.sh` | Copies the curated reports of a run into `results/<prec>/` |
| `slow.lib`, `all.lef`, `gds2_innovus-2.map` | **Not in git** (licensed course files). Copy them here on crosby3 (step 2). |

The finished run's reports are already in `results/int8/` and `results/int4/`, and the
numbers are in `results/RESULTS.md`. RTL simulation is done with `sim/run_sim.sh` (see `docs/SETUP.md`).

---

## 2. Get the files on crosby3

1. If you are off campus, connect the **GlobalProtect** VPN first.
2. Open the MobaXterm SSH session to crosby3 (as in HW7). Then:

```bash
cd ~/ee5113-kws-accelerator && git pull          # first time: see docs/SETUP.md section 3
cd flow/tsmc18
# tsmc18 library files from the Innovus tutorial / HW7 folder (not in git):
cp ~/EE5113_Hw7/slow.lib ~/EE5113_Hw7/all.lef ~/EE5113_Hw7/gds2_innovus-2.map .
ls
```

**Run every command below from `flow/tsmc18/`.** Outputs go to `out_int8/` and `out_int4/` (git-ignored).

---

## 3. Synthesis (Cadence RTL Compiler, same tool as HW7)

```bash
rc -f syn_int8.g
rc -f fmax_int8.g
rc -f syn_int4.g
rc -f fmax_int4.g
```

Each run takes a few minutes and ends with `… synthesis finished`. It returns to the shell by itself.
If your account uses Genus instead of `rc`, run `genus -legacy_ui -f syn_int8.g` (and so on).

- `syn_int*.g` → 100 MHz netlist `out_int*/kws_int*_Net.v` + reports (area, power, timing, gates, QoR)
- `fmax_int*.g` → reports only. Fmax = 1 / (2.0 ns − slack). `results.sh` does this math for you.

📸 **Screenshots to take (INT8, then the same for INT4):**

```bash
cat out_int8/kws_int8_area.rpt
cat out_int8/kws_int8_pwr.rpt
head -70 out_int8/kws_int8_time.rpt
cat out_int8/kws_int8_qor.rpt
grep -B2 -A2 "Timing slack" out_int8/kws_int8_fmax_time.rpt
```

| # | Screenshot | Report section |
|---|---|---|
| S1 | Terminal at the end of `rc -f syn_int8.g` | Tools & Methodology |
| S2 | `kws_int8_area.rpt` (cell count + area) | Results |
| S3 | `kws_int8_pwr.rpt` (leakage / dynamic / total) | Results |
| S4 | `kws_int8_time.rpt` (critical path + slack ≥ 0) | Results |
| S5 | `Timing slack` line of `kws_int8_fmax_time.rpt` (for Fmax) | Results |
| S6–S10 | The same five for INT4 | Results |

---

## 4. Place & route (Innovus)

```bash
innovus -files pnr_int8.tcl
```

The Innovus window opens and the whole flow runs by itself: floorplan → power ring/stripes → placement → CTS → routing → fillers → DRC/connectivity/antenna checks → reports → GDS.
It is done when the terminal prints **`kws_int8 place & route finished`**.

The script also tries to save layout pictures by itself (`out_int8/1_floorplan`, `2_power_grid`, `3_placement`, `4_cts`, `5_routed`, `6_final_layout`, as `.png` or `.gif`).
If they are not there, the screenshots below are enough.

📸 **Screenshots to take in Innovus (before typing `exit`):**

| # | Screenshot | How | Report section |
|---|---|---|---|
| I1 | **Final layout, whole chip** | Click in the layout window, press **F** (fit) | Results |
| I2 | **Zoomed layout** (cells + metal wires) | Zoom in with the mouse wheel on the middle of the core | Results |
| I3 | **Power ring + stripes** | Layer panel (right side): turn off all layers except Metal2/3/4 | Project Design / Results |
| I4 | **Pins around the chip** | Zoom on one edge: `w_addr`/`w_data` on top, `b_*` on the right, `x_*` on the bottom, control on the left | Project Design |
| I5 | **Clock tree** | Menu **Clock → CCOpt Clock Tree Debugger** | Results |
| I6 | **Post-route timing summary** (WNS/TNS table) | Scroll the terminal up to the `optDesign Final … Timing Summary` after `postRoute_opt` | Results |
| I7 | **DRC / connectivity / antenna = clean** | `cat out_int8/kws_int8.drc.rpt out_int8/kws_int8.conn.rpt out_int8/kws_int8.antenna.rpt` | Results |
| I8 | **Power** | `sed -n 40,55p out_int8/kws_int8_innovus_power.rpt` | Results |
| I9 | **Area / density** | `grep -A20 "Total area of Standard" out_int8/kws_int8_summary.rpt` | Results |

Then type `exit` in the Innovus terminal and do the same for INT4:

```bash
innovus -files pnr_int4.tcl
```

Take I1–I9 again for INT4. Two screenshots side by side make a nice figure: the INT8 layout next to the INT4 layout at the same zoom.

---

## 5. Results table (for the report)

```bash
bash results.sh
```

📸 **R1 – screenshot of this table.** It lists both designs: accuracy, cells, flip-flops, area, power, Fmax, layout area, slack, energy per inference, and DRC status.

**Keep the results:** copy the curated reports into the repo and push them:
```bash
./save_results.sh int8 && ./save_results.sh int4
git add ../../results && git commit -m "results: tsmc18 INT8/INT4 run" && git push
```

---

## 6. Where each screenshot goes in the final report

| Report section (from the guidelines) | Content | Screenshots / figures |
|---|---|---|
| 1. Cover page | Title, names | – |
| 2. Table of contents | – | – |
| 3. Abstract | Goal, method, main INT8 vs INT4 numbers | – |
| 4. Project overview | Keyword spotting, why low precision saves power and area | `results/python/figures/01_pipeline.png` |
| 5. Project design | Network 250→32→6, accelerator block diagram (MAC, hidden buffer, ReLU/requant, argmax, FSM), memory map, pin map | I3, I4 |
| 6. Tools and methodology | Python (training + quantization) → Vivado xsim (bit-exact check) → RC synthesis (tsmc18, 100 MHz) → Innovus | S1, 01, 06 |
| 7. Results and discussion | Accuracy vs bit width; simulation waveforms; synthesis area/power/Fmax; layout pictures; post-route timing/power; DRC clean; INT8 vs INT4 table; energy per inference | 02–05, S2–S10, I1–I9, R1, `results/python/figures/04_accuracy_all_models.png`, `05_accuracy_vs_memory.png` |
| 8. Conclusion | INT4: smaller and lower power, about 1.5 points less accuracy (86.7 % → 85.1 %) | – |
| 9. References | Google Speech Commands (Warden 2018), quantization papers, Cadence/Xilinx docs | – |
| 10. Appendix | Verilog code, scripts, full reports | – |

---

## 7. Changes from the proposal (say this in the report)

- **Library:** the class server has the **tsmc18 (180 nm)** library used in the Innovus tutorial and HW7, so it is used instead of GPDK45 (45 nm). INT8 and INT4 are compared on the same library, so the comparison is still fair.
- **Synthesis tool:** Cadence **RTL Compiler** (`rc`, the class tool and the predecessor of Genus; same commands).
- **Memories:** the weights (8 KB / 4 KB), biases and input features stay in memories outside the core, because the class library has no SRAM compiler. The chip reads them through address/data ports. The 32 hidden values are stored on-chip.
- **Fmax:** RC adds delay during area recovery until the slack is about 0 (HW7 ended with slack = 1 ps). So the 100 MHz run cannot show the maximum speed. The separate 2 ns run (`fmax_int*.g`) measures it.

---

## 8. If something goes wrong

| Problem | Fix |
|---|---|
| `rc: command not found` / `innovus: command not found` | Use the same terminal setup as HW7 (the Cadence environment loads at login, or `source` the course setup file you used then). |
| Innovus window does not open | In the MobaXterm session settings, make sure **X11-Forwarding** is on, then reconnect. |
| `ERROR: out_int8/kws_int8_Net.v not found` | Run `rc -f syn_int8.g` first, from `flow/tsmc18/`. |
| Negative WNS after routing (unlikely at 100 MHz) | Report it as is, or change `-period 10.0` to `12.0` in `kws.sdc` and run synthesis + Innovus again. |
| Want to start over | `rm -rf out_int8` (or `out_int4`) and run again. |
