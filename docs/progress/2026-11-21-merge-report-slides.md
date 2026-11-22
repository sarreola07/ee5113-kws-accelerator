# Final deliverables: merged design, report and slides

- **Date:** 2026-11-21
- **Author:** sarreola07
- **Branch / commit:** `sergio/docs-and-fixes`, fast-forwarded into `main` (this commit; based on `3310875`)
- **Machine(s):**
  - Linux (cloud session): the review, the Icarus simulations, the report and the slides;
  - the board results are chit2000's, from the Windows PC with Vivado and the team's Nexys A7-100T.

## What was done
- **The hardware-tested design is in `main`.**
  - chit2000's PR #2 was reviewed and fast-forwarded into `main`. It adds the power-on self-test, switch control,
    words from the PC microphone (`fpga/mic_demo.py`), and bitstreams for the Nexys 4 DDR / A7 and the Nexys 4.
  - What the review checked:
    - the Icarus simulations `int8`, `int4` and `fpga` pass;
    - with loudness scaling off (`--no-agc`), the PC front end gives exactly the inputs of the training front end;
    - all 48 board pins match Digilent's Nexys A7 constraints;
    - the timing reports meet setup and hold at 50 MHz.
  - PR #1, our alternative board self-check with the `kws_live.py` link, was closed without merging. Its branch
    `sergio/board-check-live-voice` stays as design exploration (slide 12,
    `2026-11-20-design-comparison-board-check.md`).
- **Fixes on top of the merge** (commits `bad3595`, `30ab000`, `3310875`):
  - `fpga/build.tcl` refuses to copy a bitstream that fails setup or hold timing, and `fpga/build.bat` then stops
    without programming the board;
  - the shell scripts are executable again, and `.gitignore` ignores `python/data/` at any depth;
  - `CLAUDE.md` names the team board (Nexys A7-100T → `nexys4ddr`) and the check for empty ROMs (`[Synth 8-4445]`).
- **Windows command blocks are safe to paste.** In Command Prompt, `::` after a command is not a comment, and `->`
  sends the output to a file. Every `bat` block in `README.md`, `docs/SETUP.md` and the progress logs now puts its
  comments on separate `REM` lines.
- **Slides (14):**
  - slide 11 shows chit2000's results on the Nexys A7-100T;
  - slide 1 has the date, November 21, 2026;
  - slides 6 and 12 name the Nexys A7-100T;
  - slide 14 lists the FPGA demo as delivered, and live-microphone accuracy as not measured.
  - The source of every number is in `docs/slides/README.md`.
- **Report** (`docs/report/EE5113_Final_Project_Report.docx` and `.pdf`, now 33 pages):
  - both names on the cover, with the date November 21, 2026; written as "we";
  - new section 4.6, "FPGA Demonstration", with the board results (Table 11); one sentence each in the Abstract and
    the Conclusion, and the FPGA item is off the future-work list;
  - the FPGA board in the objectives (§1.3), the project summary (§1.4), the design flow (§3.2, step 8), the
    verification (§3.3, `tb/tb_fpga_top.v`) and the tools (Table 5); §3.6 now says the words come from the PC's
    microphone and the MFCC front end stays in software;
  - the appendix links the public repo, and Table 12 uses the repo's paths. Its last row no longer promises GDS files,
    because `results/int8` and `results/int4` hold only reports, netlists and layout pictures;
  - the photo placeholder in §4.6 was removed (there are no photo files yet), and the table of contents was updated.
  - A separate check compared every change with the original report, and every number with `results/RESULTS.md`, the
    FPGA reports and the 2026-11-20 log. It also looked at every page: none is blank, and the table of contents
    matches the pages.

## How to reproduce / load it
Simulations (the merged design passes all three):
```bash
# where: laptop or crosby3 with Icarus Verilog (or Vivado xsim / Xcelium without the last argument)
git pull
./sim/run_sim.sh int8 iverilog      # TEST PASSED, 0 mismatches
./sim/run_sim.sh int4 iverilog      # TEST PASSED, 0 mismatches
./sim/run_sim.sh fpga iverilog      # FPGA TOP TEST PASSED
```

Board check, as chit2000 ran it:
```bat
REM where: Windows PC with Vivado and the Nexys A7-100T on USB (PROG/UART port)
fpga\program.bat nexys4ddr
REM expect: PASS on the display for 3 s, LED11 on, then rEAdY
python fpga\mic_demo.py --clips
REM expect: INT8 176/200, INT4 177/200, 400/400 same as Python -> PASS
python fpga\mic_demo.py
REM a person speaks: yes, no, on, off, left, right
```

The report PDF after editing the `.docx`:
```bash
# where: any machine with LibreOffice. In Word: update the table of contents, then Save As PDF.
soffice --headless --convert-to pdf --outdir docs/report docs/report/EE5113_Final_Project_Report.docx
```

## Files added / changed
| File | What it is | Used by |
|------|-----------|---------|
| `docs/report/EE5113_Final_Project_Report.docx`, `.pdf` | the final report, updated as above | submission |
| `docs/progress/2026-11-21-merge-report-slides.md` | this log | both partners |
| `README.md` | note on `mic_demo.py` loudness scaling; status rows; progress-log row | everyone |
| `docs/slides/README.md` | status and the one item still to fill in (the photo) | presenting, editing the deck |
| `docs/progress/2026-11-21-handoff-windows.md` | slides and report rows of the status table | the next session on the Windows PC |

## Results
On the Nexys A7-100T (chit2000, `docs/progress/2026-11-20-fpga-microphone.md`):

| Check | INT8 | INT4 |
|-------|------|------|
| Power-on self-test: words correct | 176/200 | 177/200 |
| Power-on self-test: same as Python | 200/200 | 200/200 |
| `mic_demo.py --clips` (200 clips sent from the PC) | 176/200 correct | 177/200 correct |
| … same as Python, both precisions | 400/400 | |
| 12 text-to-speech words (`--wav`) | 12/12 right, all same as Python | |
| Live words from the PC microphone | shown on the display; accuracy not measured | |

FPGA build (`results/fpga/nexys4ddr/`): 13,762 LUTs (21.71 %), 1,431 registers, 0 block RAM, 0 DSP; WNS +1.116 ns and
WHS +0.095 ns at 50 MHz (xc7a100tcsg324-1, Vivado 2024.2). The ASIC numbers did not change (`results/RESULTS.md`).

## Problems hit & fixes
- **Our own board would not power on.** The demo evidence is chit2000's board run. The power checklist (data
  cable in PROG/UART, power switch ON, JP3 on USB, another USB port) is in `2026-11-21-handoff-windows.md`.
- **Board photos:** they reached us as chat images, not files, so they are not in the repo yet. Slide 11 has an empty
  frame for photo F1.
- **Pasting into Command Prompt:** see the `REM` fix above.
- **Report PDF fonts:** the committed PDF was made with LibreOffice. It uses Carlito (the same letter widths as
  Calibri) and DejaVu Sans Mono instead of Consolas, so it looks slightly different from a Word export, and its
  table-of-contents page numbers follow the LibreOffice layout. To export from Word instead, first update the table of
  contents (right-click it → Update Field → Update page numbers only).

## Known limits of the merged FPGA design (for later; none changes the results above)
- **Empty ROMs:** if every `.mem` file is missing at build time, Vivado fills every ROM with zeros. The computed and
  expected answers can then agree, so the self-test can still show PASS. After every build, check the synthesis log
  for `[Synth 8-4445]` (`CLAUDE.md` #8).
- **One word at a time:** the board keeps one word buffer, so if two words arrive while it is busy, only the second
  one runs. A packet takes 44 ms and an inference 0.17 ms per precision, so the demo does not hit this.
- **No time limit in `tb/tb_fpga_top.v`:** if the design hangs, the simulation runs until it is stopped instead of
  failing.
- **Thin 50 MHz margin:** WNS is +1.116 ns on a 20 ns clock. A rebuild after RTL changes may fail timing; `build.tcl`
  then stops and keeps the old bitstream.

## Next steps
- [ ] Drop photo F1 into the frame on slide 11. Commit both photos as
      `docs/report/screenshots/fpga/F1_nexys_a7_mic_word_closeup.jpg` and `F2_nexys_a7_board_overview.jpg`.
- [ ] Export the deck as `.pptx` and `.pdf` into `docs/slides/`.
- [ ] Rehearse with the speaker notes and decide who presents which slides.
- [ ] Live demo on chit2000's board, or on ours once it powers on.
- [ ] Optional: measure live-microphone accuracy (for example 10 tries per word) and add it to slide 14.
- [ ] Optional, in Word: update the table of contents, then Save As PDF to get the original fonts.
