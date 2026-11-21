# Handoff: continue on the Windows PC (Vivado + Nexys A7-100T)

- **Date:** 2026-11-21. Rewritten after PR #2 was merged into `main`.
- **Author:** sarreola07
- **Branch:** `main`
- **Machine:** the Windows PC with Vivado and the team's **Nexys A7-100T**. Its bitstream name is **`nexys4ddr`**; the
  A7-100T has the same pins as the Nexys 4 DDR.

## Start here: a new Claude Code session on the Windows PC
1. If the repo isn't on this PC yet, do `docs/SETUP.md` §2 first, then clone.
2. Open the repo folder in Claude Code and send:

   > git fetch, git switch main, git pull. Then read docs/progress/2026-11-21-handoff-windows.md and walk me
   > through it one step at a time. Stop after each step and tell me what to check on the board.

`CLAUDE.md` loads automatically. Its rules (authorship, what never to commit) apply to everything below.

## Where things stand
| Part | State |
|---|---|
| Design in `main` | chit2000's design from PR #2: power-on self-test, switch control, and words from the PC microphone (`fpga/mic_demo.py`). Prebuilt bitstreams exist for the Nexys 4 DDR / A7 and for the original Nexys 4. |
| Board results | On a Nexys A7-100T (chit2000, `docs/progress/2026-11-20-fpga-microphone.md`):<br>• self-test: INT8 176/200 and INT4 177/200 correct, 200/200 same as Python each<br>• `mic_demo.py --clips`: 400/400 same as Python<br>• text-to-speech words: 12/12<br>• live microphone words: shown on the display |
| Our own board | Not run yet. It would not power on (2026-11-21); see "If something fails". |
| PR #1 | Our alternative FPGA design (a board self-check that compares all 6 scores, and the `kws_live.py` UART link). It stays on branch `sergio/board-check-live-voice` and was not merged. |
| Slides | 14 slides, online. The FPGA slide has the board results. Still to add: the presentation date and the board photo. |
| Report | Updated 2026-11-21 (names, section 4.6 FPGA demonstration). See the 2026-11-21 progress log. |

## On the Windows PC, in order
Each command is given twice:
- for a person in Command Prompt or PowerShell;
- for Claude Code, whose shell on Windows is Git Bash.

### 1. Power and preflight
- **Power:**
  - a data-capable micro-USB cable in the **PROG/UART** port (a charge-only cable won't work);
  - the power switch **ON**;
  - the power-select jumper JP3 on **USB**, unless you use a 5 V wall supply.
  - The red POWER LED must light.
- **Tools:**
  ```bash
  # Git Bash (Claude Code), repo root
  git --version && python --version
  ls /c/Xilinx/Vivado/          # the installed Vivado version folder, e.g. 2024.2
  ```

### 2. Optional: simulate in Vivado xsim
```powershell
# PowerShell, repo root
.\sim\run_sim.ps1 int8
.\sim\run_sim.ps1 int4
.\sim\run_sim.ps1 fpga
```
```bash
# Git Bash (Claude Code)
powershell -ExecutionPolicy Bypass -File sim/run_sim.ps1 fpga     # also int8, int4
```
`int8` and `int4` must end in `TEST PASSED`, and `fpga` in `FPGA TOP TEST PASSED`.

### 3. Program the prebuilt bitstream (no build needed)
```bat
:: Command Prompt, repo root. If vivado isn't found, first run C:\Xilinx\Vivado\<version>\settings64.bat
fpga\program.bat nexys4ddr
```
```bash
# Git Bash (Claude Code). Clears the variable that breaks Vivado's .bat files in agent shells (CLAUDE.md #6).
env -u NoDefaultCurrentDirectoryInExePath cmd //c 'call C:\Xilinx\Vivado\2024.2\settings64.bat && call fpga\program.bat nexys4ddr'
```
What to expect: the display shows `--------` during the self-test, then `  PASS  ` for 3 s with **LED11 on**, then
` rEAdY  `.

### 4. At the board
- **One clip:** with SW14 down, SW7–SW0 pick a clip, which then runs automatically. For example, `00000101` shows
  `  5  YES`.
- **All 200 clips:** SW14 up shows `176  200` (INT8). Then SW15 up shows `177  200` (INT4).

### 5. Words from the PC microphone
```bat
python -m pip install numpy pyserial sounddevice
REM expect 400/400 same as Python
python fpga\mic_demo.py --clips
REM a person speaks: yes, no, on, off, left, right
python fpga\mic_demo.py
```
- **What the board does:** it shows the word, and the PC prints the board's answer next to Python's.
- **`--clips` and `--wav`** need no input, so Claude can run them. Live `mic_demo.py` needs a person at the microphone.
- **The COM port:** only one program can open it at a time. Close PuTTY or `fpga\monitor.ps1` before running
  `mic_demo.py`.

### 6. Record the results (Claude does this)
1. **Photos:** put them in `docs/report/screenshots/fpga/` as `F1_nexys_a7_mic_word_closeup.jpg` and
   `F2_nexys_a7_board_overview.jpg`. Drop F1 into the photo frame on slide 11.
2. **Progress log:** write `docs/progress/<date>-board-test.md` from `docs/progress/TEMPLATE.md`, with:
   - what the display showed;
   - the `--clips` output;
   - the live words tried and how many were right.
3. **README:** update the status rows and add the progress-log row.
4. **Commit and push:** commit as sarreola07 (see `CLAUDE.md` → Authorship), run the pre-push check described there,
   then push.

### 7. Only if the FPGA design changes
```bat
REM about 20 min; keep the PC awake. Stops, and does not program the board, if timing fails.
fpga\build.bat nexys4ddr program
```
After the build, search `fpga\work\nexys4ddr\kws_fpga.runs\synth_1\runme.log` for `[Synth 8-4445]`. That warning
means a `.mem` file was missing, and Vivado filled that ROM with zeros (CLAUDE.md #8).

## If something fails
| Symptom | Fix |
|---|---|
| The board doesn't power on (no red POWER LED) | Use a data micro-USB cable in PROG/UART, switch the power ON, put JP3 on USB, and try another USB port on the PC |
| It programs, but the display stays dark or wrong | Wrong bitstream: the Nexys A7-100T needs `nexys4ddr` |
| `vivado` not recognized | Call `settings64.bat` first (step 3) |
| Vivado `.bat` files fail from Claude's shell ("Spawn failed") | Clear `NoDefaultCurrentDirectoryInExePath` (step 3, CLAUDE.md #6) |
| `mic_demo.py` can't open the COM port | Close PuTTY or `monitor.ps1`, check Device Manager → Ports |
| The self-test shows `FAIL` | Program again; if you rebuilt, check `[Synth 8-4445]` (step 7) |

There is more in `docs/SETUP.md` §7.

## Rules for this session (from CLAUDE.md)
- **Authorship:**
  - commits are authored and committed as sarreola07 with the noreply email, and signing is off;
  - no `Co-Authored-By` or `Claude-Session` lines, and no credit in docs or slides;
  - run the pre-push check before every push.
- **Never commit** `work/`, `fpga/work/`, logs, or the tsmc18 library files.
- **One `rtl/kws_accel.v`** serves simulation, the ASIC flow and the FPGA. If any arithmetic changes, change
  `python/quant.py` too, and rerun int8, int4 and fpga.
