# Handoff: continue on the Windows PC (Vivado + Nexys board)

- **Date:** 2026-11-21
- **Author:** sarreola07
- **Branch:** `sergio/board-check-live-voice`, draft PR #1 into `main`:
  <https://github.com/sarreola07/ee5113-kws-accelerator/pull/1>
- **Machine:** the Windows PC with Vivado and the Nexys board (micro-USB in the board's **PROG/UART** port).

## Update, 2026-11-21: read this first
- **New:** chit2000 pushed **PR #2** (`chit2000/mic-demo`):
  - <https://github.com/sarreola07/ee5113-kws-accelerator/pull/2>;
  - a power-on self-test, switch control, and words from the PC microphone (`fpga/mic_demo.py`);
  - **tested on a Nexys A7-100T**;
  - prebuilt bitstreams for the Nexys 4 DDR / A7 and for the original Nexys 4.
- **Conflict:** PR #2 and this branch (PR #1) change the same FPGA files, so only one can go into `main` as is. A review
  of both is running. This file will be updated with the chosen design.
- **Fastest board demo today, no build** (from PR #2's own log, `docs/progress/2026-11-20-fpga-microphone.md` on that
  branch):
  ```bat
  :: Command Prompt, repo root; board on USB-PROG/UART; all switches down
  git fetch
  git switch chit2000/mic-demo
  fpga\program.bat nexys4          :: original Nexys 4 (nexys4ddr for a Nexys 4 DDR / A7-100T)
  python -m pip install numpy pyserial sounddevice
  python fpga\mic_demo.py --clips  :: expect 400/400 same as Python
  python fpga\mic_demo.py          :: then say yes / no / on / off / left / right
  ```
  - At power-on the display shows `--------`, then `  PASS  ` for 3 s with LED11 on.
  - SW14 up shows `176  200` (INT8). Then SW15 up shows `177  200` (INT4).
  - Check the board label first: a bitstream for the wrong Nexys variant programs fine but does nothing.
- **Below:** the steps for PR #1's design (build, BTNU self-check, `kws_live.py`). They still apply if PR #1's design is
  kept.

## Start here: a new Claude Code session on the Windows PC
1. If the repo isn't on this PC yet, do `docs/SETUP.md` §2 first: Git, Python 3.11, Vivado, Claude Code, then clone.
2. Open the repo folder in Claude Code and send:

   > git fetch, git switch sergio/board-check-live-voice, git pull. Then read
   > docs/progress/2026-11-21-handoff-windows.md and walk me through it one step at a time, starting with the
   > preflight. Stop after each step and tell me what to check on the board.

`CLAUDE.md` loads automatically. Its rules (authorship, what never to commit) apply to everything below.

## Where things stand
| Part | State |
|---|---|
| `main` (chit2000) | Trained INT8/INT4 model, bit-exact RTL, tsmc18 layouts, an FPGA demo bitstream for the Nexys 4 DDR. That bitstream was never tested on a board. |
| This branch | Board self-check (PASS / FAIL / Err, SW14 fault test), live words over the USB-UART (`fpga/kws_live.py`), review fixes, slide sources |
| Verified | In a cloud session with Icarus and Python:<br>• RTL vs Python: 0 mismatches, INT8 and INT4<br>• board testbench: every scenario<br>• UART cross-check: 8/8<br>• live front end: 50,000/50,000<br>• `kws_live.py --mock --selftest`: 200/200 |
| **Not verified yet** | **Vivado xsim** on the new UART files, **the Vivado build and its timing**, and **everything on the real board** |
| Slides | A 14-slide mock deck, online (Sergio has the link). The board results are placeholders. `docs/slides/README.md` lists the source of every number. |

## On the Windows PC, in order
Each command is given twice:
- for a person in Command Prompt or PowerShell;
- for Claude Code, whose shell on Windows is Git Bash.

### 1. Preflight
```bash
# Git Bash (Claude Code), repo root
git --version && python --version
ls /c/Xilinx/Vivado/          # the installed Vivado version folder, e.g. 2024.2
```
- **Board:** power switch on, micro-USB in **PROG/UART**. Device Manager → Ports should show a USB Serial Port (COMx).
- **Which board?** Read the label. Use the name below wherever this file says `<board>`:

  | Label | `<board>` |
  |---|---|
  | Nexys 4 DDR or Nexys A7-100T | `nexys4ddr` |
  | plain Nexys 4 | `nexys4` |
  | Nexys A7-50T | `nexys_a7_50t` |

### 2. Simulate in Vivado xsim
This is the first time xsim sees the UART files.
```powershell
# PowerShell, repo root
.\sim\run_sim.ps1 int8
.\sim\run_sim.ps1 int4
.\sim\run_sim.ps1 fpga
```
```bash
# Git Bash (Claude Code)
powershell -ExecutionPolicy Bypass -File sim/run_sim.ps1 int8     # then int4, then fpga
```
- All three must end in `TEST PASSED`. The fpga run takes a few minutes and ends with `*** FPGA TOP TEST PASSED ***`.
- If xsim rejects something that Icarus accepted, fix the Verilog, rerun all three, then continue.

### 3. Build and program the board
This takes about 25 minutes.
```bat
:: Command Prompt, repo root. If vivado isn't found, first run C:\Xilinx\Vivado\<version>\settings64.bat
fpga\build.bat <board> program
```
```bash
# Git Bash (Claude Code). Clears the variable that breaks Vivado's .bat files in agent shells (CLAUDE.md #6).
# Replace 2024.2 and nexys4 with what step 1 found.
env -u NoDefaultCurrentDirectoryInExePath cmd //c 'call C:\Xilinx\Vivado\2024.2\settings64.bat && call fpga\build.bat nexys4 program'
```
- **Success:** the log prints `Timing met: setup WNS = … ns, hold WHS = … ns`, then the board is programmed.
- **`timing FAILED`:** nothing is copied to `results/fpga` and the board is not programmed.
  - Setup failure (WNS < 0): use the 40 MHz fallback in `docs/progress/2026-11-20-design-comparison-board-check.md`
    ("Not verified yet"), then rebuild.
  - Hold failure (WHS < 0): look at the failing paths in `fpga\work\<board>\timing_summary.rpt`.
- **Write down** WNS, WHS, and the LUT and flip-flop counts from `results\fpga\<board>\utilization.rpt`.

### 4. Board self-check (a person at the board)
| Do | Expect |
|---|---|
| SW15 down, press BTNU | green LED16, display `PASS 176` |
| SW15 up, press BTNU | green LED16, `PASS 177` |
| SW14 up, SW15 down, press BTNU, then SW14 down again | red LED16, `F000 199` |
| SW7–SW0 = 2 (binary 00000010), press BTNC | `  2 LEFt` |

Take a photo of the board showing `PASS 176`; it goes on slide 11.

### 5. Live words from the PC
```bash
# Git Bash (PowerShell: .venv\Scripts\Activate.ps1 instead of the source line)
python -m venv .venv && source .venv/Scripts/activate
pip install -r fpga/requirements-live.txt
python fpga/kws_live.py --selftest        # expect SELFTEST PASSED, 200/200 for INT8 and INT4
```
- **`--selftest`** needs no input, so Claude can run it.
- **`--mic` needs a person:** it waits for Enter before each word, so run it in your own terminal, not in Claude's
  shell:
  ```bash
  python fpga/kws_live.py --mic                  # INT8; say yes / no / on / off / left / right
  python fpga/kws_live.py --mic --prec int4
  ```
- **What `--mic` shows:** the board displays `LI <word>`, and the PC prints `board == Python` for each word. Count how
  many words are right, for example 5 tries per word, so 30 per precision.
- **`No board answered`:** the board must be running the bitstream from step 3. Close any serial terminal, or pass
  `--port COMx`.

### 6. Record the results (Claude does this)
1. **Check what to commit.** `git status` should show the new `results/fpga/kws_fpga_top_<board>.bit` and
   `results/fpga/<board>/*.rpt`. The build copies them only when timing passed. Never add `fpga/work/`, `work/` or
   logs.
2. **Write the log.** Create `docs/progress/<date>-board-test.md` from `docs/progress/TEMPLATE.md`, with:
   - what the display showed for each row of step 4;
   - WNS, WHS, LUTs and flip-flops;
   - the `--selftest` output;
   - the live-word counts;
   - any problem and its fix.
3. **README:** set the FPGA self-check and live-words status rows to done on the board, and add the progress-log row.
4. **Commit and push.** Commit as sarreola07 (see `CLAUDE.md` → Authorship), run the pre-push check described there,
   then push.

### 7. Slides
Fill in the placeholders listed in `docs/slides/README.md`:
- slide 1: the presentation date;
- slide 11: the "On the board" column, the board photo, and which board was used;
- slide 14: the board-test line;
- the title-slide notes may then say that the design ran on a Nexys board.

If this session can edit the online deck, make the changes there. Otherwise, write out the exact replacement text for
Sergio. Then update the placeholder list in `docs/slides/README.md`, and export the deck as `.pptx` and `.pdf` into
`docs/slides/`.

### 8. Pull request
- After the board test passes, mark PR #1 ready for review and ask chit2000 to review it. The review notes for `main`
  are in the 2026-11-20 log.
- The PR description ends with a tool footer line. Delete it by hand on GitHub.

## If something fails
| Symptom | Fix |
|---|---|
| Vivado `.bat` files fail from Claude's shell ("Spawn failed") | Clear `NoDefaultCurrentDirectoryInExePath` as in step 3 (CLAUDE.md #6) |
| `vivado` not recognized | Call `settings64.bat` first, as in step 3 |
| xsim reports an error Icarus didn't | Fix the Verilog for xsim, then rerun int8, int4 and fpga |
| `Err ----` | A golden-data `.mem` file was missing or damaged: `python fpga/gen_fpga_mem.py --check`, then rebuild |
| `F000   0` | A weights, biases or inputs `.mem` file was missing at build time: search `fpga\work\<board>\kws_fpga.runs\synth_1\runme.log` for `[Synth 8-4445]` |
| BTNU passes, `--selftest` fails | `fpga/mem` is older than `weights/`: `python fpga/gen_fpga_mem.py`, then rebuild |
| `No board answered` | See step 5 |

There is more in `docs/SETUP.md` §7.

## Rules for this session (from CLAUDE.md)
- **Authorship:**
  - commits are authored and committed as sarreola07 with the noreply email, and signing is off;
  - no `Co-Authored-By` or `Claude-Session` lines, and no credit in docs or slides;
  - run the pre-push check before every push.
- **Never commit** `work/`, `fpga/work/`, logs, or the tsmc18 library files.
- **One `rtl/kws_accel.v`** serves simulation, the ASIC flow and the FPGA. If any arithmetic changes, change
  `python/quant.py` too, and rerun int8, int4 and fpga.

## Later (not needed for the board test)
- The report cover still says "Student Name: ____".
- chit2000's review of this PR and of the review notes for `main`.
