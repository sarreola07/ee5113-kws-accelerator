# Final presentation slides

- **Status:** 14 slides. The FPGA slide has the board results of the merged design (Nexys A7-100T). Still to add: the
  presentation date and the board photo.
- **Final files:** export the finished deck as `.pptx` and `.pdf` and commit both to this folder.
- **Length:** about 10 minutes. That is the team's own target; the course sets no length.
- **Required sections, in this order** (`docs/reference/Final_Project_Guidelines.pdf`, p1–2):
  1. title page (project title and student names)
  2. outline
  3. project overview
  4. project design
  5. tools and methodology
  6. results and discussion
  7. conclusion/summary
- **Colors:** INT8 is blue and INT4 is orange on every slide.
- **Speaker notes:** every slide has a full script, about 1,400 words in total.
- **Audit:** all 291 claims on the slides, in the notes and in the footers were traced to repo files. Five wording
  problems were fixed; see `docs/progress/2026-11-20-slides-draft.md`. On 2026-11-21 the FPGA slide was rewritten with
  the board results of the merged design; its numbers were checked against `results/fpga/nexys4ddr/*.rpt` and the
  2026-11-20 microphone log.

## Slides and where every number comes from

| # | Section | Slide | Numbers and claims | Source |
|---|---|---|---|---|
| 1 | Title page | Title | title, subtitle, course, instructor, Fall 2026 | final report cover |
| 2 | Outline | Outline | the five sections | course guidelines |
| 3 | Overview | Problem and System | the question from the proposal; the six words; system figure | `docs/reference/Project_Proposal.pdf` p1; report Figure 1 |
| 4 | Design | Network and Quantization | Speech Commands v0.02, 23,154 clips (18,470 / 2,254 / 2,430); MFCC 25 × 10 = 250; 250 → 32 → 6; FP32 then QAT per bit width; histograms of the 8,000 layer-1 weights | `python/config.py`, `results/python/logs/prepare_data.txt`, `results/python/float_weights.npz`, `qmodel_int*.npz` |
| 5 | Design | Accelerator Architecture | one shared MAC; accumulator 23 / 15 bits; ReLU, round half up, shift 9 / 5; 8,270 cycles = 82.7 µs at 100 MHz | `rtl/kws_accel.v`, `weights/int*/kws_params.vh`, `README.md`; report Figure 3 |
| 6 | Tools and methodology | Design Flow | Python → RTL → RTL Compiler → Innovus → Vivado; the six Innovus steps | `python/`, `sim/`, `flow/tsmc18/`, `fpga/`; `results/int8/layout/` |
| 7 | Results | Accuracy | FP32 86.0 %, INT8 86.7 %, INT4 85.1 % on 2,430 clips; 32 / 8 / 4 KB of weights; INT4 by plain rounding 83.7 %, so QAT recovers 1.4 points | `results/python/results.csv` |
| 8 | Results | Bit-Exact Verification | 0 mismatches in 6,400 hidden values, 1,200 scores and 200 classes per precision; 176 / 177 of 200 words correct | `tb/tb_kws.v`, `weights/int*/summary.txt` |
| 9 | Results | Chip Layouts | 79,401 → 46,802 µm² (−41 %); setup slack +0.079 / +0.228 ns at 100 MHz; Innovus DRC, connectivity and antenna checks clean | `results/RESULTS.md`; report Figure 13 |
| 10 | Results | INT8 vs INT4 | accuracy, chip area, power, energy per word, max clock, setup slack | `results/RESULTS.md` |
| 11 | Results | FPGA Demonstration | on the Nexys A7-100T: self-test INT8 176/200 and INT4 177/200 correct, 200/200 same as Python each; 200 test clips sent from the PC 400/400 same as Python; 12/12 text-to-speech words; live microphone words shown; 13,762 LUTs (21.7 %), 1,431 registers, 0 block RAM, 0 DSP, setup +1.116 ns / hold +0.095 ns at 50 MHz | `docs/progress/2026-11-20-fpga-microphone.md`, `results/fpga/nexys4ddr/` |
| 12 | Results | Design Exploration | the final design vs the earlier version in `alt/`; worth carrying forward: INT6, its 15 unit tests (run by hand, CI to add), a one-inference VCD for activity-based power, block-RAM-friendly memories; also explored: the score-checking board self-check on branch `sergio/board-check-live-voice` (simulated only) | `docs/progress/2026-11-20-design-comparison-board-check.md`, `alt/sergio_bram_design/` |
| 13 | Conclusion | Summary | −50 % power and energy per word, −41 % chip area, −1.5 accuracy points | `results/RESULTS.md`, `results/python/results.csv` |
| 14 | Conclusion | Conclusion and Next Steps | delivered vs the proposal (plus the FPGA demo), limits (including: live-microphone accuracy not measured), next steps | proposal; report §3.6, §4.5, §4.6; `docs/progress/2026-11-20-design-comparison-board-check.md` |

Differences on the slides are computed from the repo values; the arithmetic is in the speaker notes:
- chip area: (79,401 − 46,802) / 79,401 = 41.1 %;
- power: (3.843 − 1.919) / 3.843 = 50.1 %;
- accuracy: 86.67 − 85.14 = 1.53 points;
- QAT gain at INT4: 85.14 − 83.74 = 1.40 points.

## Still to fill in
- Slide 1: the presentation date.
- Slide 11: the board photo. Drop `F1_nexys_a7_mic_word_closeup.jpg` into the frame; the caption under it
  describes that photo (LED11 self-test passed, LED10 microphone word, LED13 INT8 and INT4 equal Python).

## Caveats the slides state (keep them when editing)
- **Max clock** (268 / 315 MHz) comes from separate synthesis-only runs (2 ns target, no I/O delay), not from the
  routed chips.
- **Power** is the Innovus estimate:
  - without simulated switching activity (default 0.2);
  - without the external weight memory;
  - at the slow corner only.
- **Layout checks:** "Clean" means Innovus' own DRC, connectivity and antenna checks. There is no LVS and no gate-level
  simulation.
- **FPGA board results** come from the teammate's test of the merged design on a Nexys A7-100T
  (`docs/progress/2026-11-20-fpga-microphone.md`). "Same as Python" compares the predicted word, not the scores.
  Live-microphone accuracy was not measured.

## Figures
```bash
# laptop or any machine with the Python requirements (needs matplotlib)
python docs/slides/make_slide_figures.py     # writes work/slides/*.png (git-ignored)
```
- `report_fig1_system.png`, `report_fig3_block_diagram.png`, `report_fig13_layouts_same_scale.png`: figures 1, 3 and 13,
  taken from `docs/report/EE5113_Final_Project_Report.docx`.
- `weight_histograms_deck.png`: `results/python/figures/06_weight_histograms.png` redrawn in the deck's colors.
- The design-flow strip uses `docs/report/screenshots/innovus/stages/int8_1…6`.
- Not used:
  - `results/python/figures/01_pipeline.png` still says "45 nm" and "on-chip ROM";
  - the full-window final layouts (`I1_*`) are not at the same scale;
  - the Vivado console screenshots show a personal Windows path.
