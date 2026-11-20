# Presentation deck: mock with placeholders

- **Date:** 2026-11-20
- **Author:** sarreola07
- **Branch:** `sergio/board-check-live-voice` (draft pull request into `main`)
- **Machine(s):** cloud Linux session for the figures and checks. The deck is an online slide deck that is exported to
  `.pptx` and `.pdf` for the class.

## What was done
- **A 14-slide mock deck** in the order the course requires (`docs/reference/Final_Project_Guidelines.pdf`):
  - title page, outline, project overview, project design, tools and methodology, results and discussion,
    conclusion;
  - about 10 minutes, with a full speaker script on every slide;
  - details in `docs/slides/README.md`.
- **Every number comes from a repo file.** `docs/slides/README.md` lists the source of each one, and the caveats that
  must stay with them (synthesis-only max clock, power estimates, prebuilt FPGA bitstream).
- **Numbers audit:**
  - Five independent checkers traced **291 claims** on the slides, in the notes and in the footers to repo files.
  - A skeptic per group then tried to refute each finding.
  - **5 problems were confirmed and fixed:**
    - the title notes said both versions ran "on an FPGA board"; no board run is recorded, so they now say "built into one
      FPGA bitstream";
    - the outline notes said "most of the time" goes to results; it is the biggest part, about 43 % of the script;
    - slide 12 and its notes credited the earlier version with tests that "run automatically" and "power from simulated
      activity". It has 15 unit tests run by hand and a one-inference VCD dump.
    - the conclusion footer now also cites report §4.5 and the 2026-11-20 log.
  - **12 flags were refuted**, because the repo backs the slide as written: for example the +17.5 % max clock
    (`results/RESULTS.md`) and the 8 of 8 UART replies (`sim/uart_xcheck.py`).
- **Placeholders:**
  - the board-test results on slide 11 (FPGA demo) and slide 14 (conclusion);
  - the board photo;
  - the presentation date.
- **New script `docs/slides/make_slide_figures.py`:**
  - extracts the report's figures 1, 3 and 13 from the `.docx`;
  - redraws the weight histograms so that INT8 is blue and INT4 orange, as on every other slide.

## How to reproduce / load it
```bash
# where: laptop with the Python requirements (python/requirements.txt, includes matplotlib)
git pull
python docs/slides/make_slide_figures.py     # writes work/slides/*.png (git-ignored)
```
The four PNGs are byte-identical to the ones in the deck: the three report figures and the redrawn histogram.

## Files added / changed
| File | What it is | Used by |
|------|-----------|---------|
| `docs/slides/README.md` | slide list, the source of every number, placeholders, caveats, figures | both partners, when editing or presenting |
| `docs/slides/make_slide_figures.py` | figure script for the deck | rebuilding or editing the deck's figures |
| `docs/progress/2026-11-20-slides-draft.md` | this log | |
| `README.md` | status row and progress-log row | |

## Results (the numbers the slides use)
| Metric | INT8 | INT4 | Source |
|--------|------|------|--------|
| Test accuracy (2,430 clips) | 86.67 % | 85.14 % | `results/python/results.csv` |
| Chip area after routing | 79,401 µm² | 46,802 µm² (−41.1 %) | `results/RESULTS.md` |
| Total power (estimate) | 3.843 mW | 1.919 mW (−50.1 %) | `results/RESULTS.md` |
| Energy per word | 317.8 nJ | 158.7 nJ | `results/RESULTS.md` |
| Max clock (synthesis only) | 268 MHz | 315 MHz (+17.5 %) | `results/RESULTS.md` |
| Setup slack at 100 MHz | +0.079 ns | +0.228 ns | `results/RESULTS.md` |
| RTL vs Python, 200 clips | 0 mismatches | 0 mismatches | `tb/tb_kws.v` |

## Problems hit & fixes
- **`results/python/figures/01_pipeline.png`** still says "45 nm" and "on-chip ROM". The deck uses report Figure 1
  instead, which has the correct labels.
- **Two layout figures:** the full-window final layouts (`I1_*`) are zoomed differently, so the deck uses report
  Figure 13, which shows both chips at the same scale.
- **Histogram colors:** the repo's chart colors INT8 orange and INT4 green, the opposite of the rest of the deck. It was
  redrawn from the same weight files.
- **Console screenshots** show a personal Windows path, so they were not used.

## Next steps
- [ ] Board test (checklist in the pull request), then fill the placeholders on slides 11 and 14, plus the date.
- [ ] Both partners: read the speaker notes and decide who presents which slides.
- [ ] Export the deck as `.pptx` and `.pdf` into `docs/slides/`.
- [ ] The report cover still says "Student Name: ____".
