# SETUP — environment and how to load the files

> **This is the living setup guide.** If you follow it from top to bottom on a
> fresh machine, you should end up able to run every part of the project.
> Whenever a step changes, it is updated here, in the same commit as the change
> (see `CLAUDE.md`). Last updated: **2026-11-19** (combined design: trained model, tsmc18 flow, FPGA demo).

## 0. What runs where

| Task | Machine | Tools |
|------|---------|-------|
| Edit code and docs, use Claude | any laptop (Mac or Windows) | Git, VS Code (optional), Claude Code |
| Train and quantize the network | any laptop or a Linux lab machine | Python 3.10+ with PyTorch, NumPy, matplotlib (`python/requirements.txt`) |
| RTL simulation (bit-exact check) | Windows/Linux with Vivado, or crosby3 | Vivado xsim (`sim/run_sim.ps1`, `sim/run_sim.sh`), Xcelium (crosby3) or Icarus |
| Synthesis + place & route | **crosby3.utsarr.net** only | Cadence RTL Compiler (`rc`) + Innovus 20.1, TSMC 180 nm (tsmc18) |
| FPGA build + program the board | **Windows** laptop (or Linux) | Xilinx Vivado (not available for macOS) |

GitHub (`https://github.com/sarreola07/ee5113-kws-accelerator`, public) is the
single source of truth. Every machine has its own clone, and you move work between
them with `git push` / `git pull`. Never copy files by hand between machines.

---

## 1. One-time: GitHub access (both partners)

1. Each partner needs a GitHub account.
2. The owner (`sarreola07`) invites the partner. Go to the repo → **Settings → Collaborators → Add people**,
   enter the partner's username, and the partner accepts the email invite.
3. Tell Git who you are, once on every machine:
   ```bash
   git config --global user.name  "Your Name"
   git config --global user.email "you@example.com"
   git config --global pull.rebase true
   ```

## 2. One-time: laptop setup

### Windows
1. **Git for Windows**: <https://git-scm.com/download/win>. Accept the defaults; this also gives you *Git Bash*.
2. **Python 3.11**: <https://www.python.org/downloads/>. Tick *"Add python.exe to PATH"*.
3. **MobaXterm** (SSH + X11 to crosby3): <https://mobaxterm.mobatek.net/>. You may already have it.
4. **Xilinx Vivado ML Standard** (free; supports the Artix-7 XC7A100T): <https://www.xilinx.com/support/download.html>.
   During install, select *Artix-7* devices only, which saves space. The cable drivers are also installed.
5. *(optional)* **Icarus Verilog** for quick local simulation: <https://bleyer.org/icarus/>. Add it to PATH.
6. **Claude Code**: <https://claude.com/claude-code>. Use the desktop app, or the CLI from Git Bash.

### Mac
1. **Git**: run `xcode-select --install`.
2. **Homebrew** (<https://brew.sh>), then:
   ```bash
   brew install python@3.11 icarus-verilog
   brew install --cask xquartz      # X11 so Cadence GUIs display on the Mac; log out and back in after install
   ```
3. **UTSA VPN client**: install it as UTSA IT instructs. It's required before you can reach crosby3 from off-campus.
4. **Claude Code**: <https://claude.com/claude-code>.
5. Vivado does **not** run on macOS. Do the FPGA builds on the Windows machine.

### Clone + Python environment (Mac and Windows)
```bash
cd ~/Documents                     # or wherever you keep projects
git clone https://github.com/sarreola07/ee5113-kws-accelerator.git
cd ee5113-kws-accelerator
python -m venv .venv               # Mac: python3 -m venv .venv
source .venv/bin/activate          # Windows Git Bash: source .venv/Scripts/activate
pip install -r python/requirements.txt
```

Quick check (no dataset needed: the trained weights are committed in `weights/`):
```bash
.\sim\run_sim.ps1 int8           # Windows + Vivado   -> TEST PASSED, 0 mismatches (also int4, fpga)
./sim/run_sim.sh int8              # Linux / Mac (xsim, Xcelium or Icarus)
```
To retrain, `python python/prepare_data.py` first downloads Speech Commands (~2.3 GB stream, keeps ~700 MB
in the git-ignored `python/data/`); see `python/README.md`.

## 3. One-time: crosby3 (Cadence server)

### Connect
- **Windows / MobaXterm** (from the Cadence tutorial): **Session → SSH**, *Remote host* `crosby3.utsarr.net`,
  tick *Specify username*, then enter your `abc123` → OK. X11 forwarding is on by default.
- **Mac**: connect to the UTSA VPN, open XQuartz, and in Terminal run:
  ```bash
  ssh -Y abc123@crosby3.utsarr.net
  ```
- Keep **only one crosby3 session** open at a time, as the course asks.

### Load the Cadence environment (every login)
```bash
source /home/opt2/setmyenv
which rc innovus xrun              # all three should print a path
```
*Optional:* to make this automatic, add the `source` line to `~/.bashrc`, or to `~/.cshrc` if your shell is csh. Check your shell with `echo $SHELL`.

### Git + GitHub on crosby3 (once)
```bash
git --version                                  # must print a version
ssh-keygen -t ed25519 -C "crosby3"             # press Enter for all prompts
cat ~/.ssh/id_ed25519.pub                      # copy this whole line
```
On GitHub, go to **your profile → Settings → SSH and GPG keys → New SSH key**, paste the line and save. Then:
```bash
ssh -T git@github.com                          # "Hi <user>! You've successfully authenticated"
cd ~
git clone git@github.com:sarreola07/ee5113-kws-accelerator.git
cd ee5113-kws-accelerator
git config --global user.name "Your Name"; git config --global user.email "you@example.com"
git config --global pull.rebase true
```
**If `ssh -T git@github.com` hangs** (port 22 blocked), use HTTPS instead.
Create a token at GitHub → Settings → Developer settings → *Personal access tokens (classic)*
with the `repo` scope. Then run:
```bash
git clone https://github.com/sarreola07/ee5113-kws-accelerator.git
git config --global credential.helper store    # first push asks for username + token (as password)
```
**If crosby3 can't reach GitHub at all**, keep the clone on your laptop and
transfer files with MobaXterm's SFTP side panel, or with `scp -r` from a Mac.
Record that in a progress log so your partner knows.

### tsmc18 library files for the ASIC flow (on crosby3, once per clone)
The flow in `flow/tsmc18/` uses the same TSMC 180 nm files as the Innovus tutorial and HW7. They are
licensed course files, so they are **not in git** (the repo is public). Copy them next to the scripts:
```bash
cd ~/ee5113-kws-accelerator/flow/tsmc18
cp ~/EE5113_Hw7/slow.lib ~/EE5113_Hw7/all.lef ~/EE5113_Hw7/gds2_innovus-2.map .   # or from the tutorial folder
```
Then follow `flow/tsmc18/RUN_GUIDE.md` (synthesis, Fmax runs, Innovus, `results.sh`, `save_results.sh`).
The other version of the design (`alt/sergio_bram_design/`) has a Genus + gpdk045 flow instead; its paths
go in `alt/sergio_bram_design/flow/config.tcl`.

## 4. FPGA: Nexys 4 / Nexys 4 DDR / Nexys A7 (Windows + Vivado)

1. **Identify your board.** The label is printed on the board:
   - **Nexys 4 DDR** or **Nexys A7-100T** → `nexys4ddr`
   - plain **Nexys 4** (no "DDR") → `nexys4`
   - **Nexys A7-50T** → `nexys_a7_50t`

   The pin files in `fpga/constraints/` follow Digilent's official master XDC files.
2. Plug the micro-USB cable into the board's **PROG/UART** port and power it on. The same cable carries
   programming and the UART used for live words.
3. Open a **Command Prompt** in the repo folder. If `vivado` isn't found, first run
   `C:\Xilinx\Vivado\<version>\settings64.bat`. Build and load the bitstream:
   ```bat
   fpga\build.bat nexys4 program
   ```
   - It takes about 25 minutes and writes `results\fpga\kws_fpga_top_<board>.bit` and the reports.
   - **It stops with an error, and does not copy the bitstream, if setup or hold timing fails.**
   - The design runs at 50 MHz (MMCM).
   - `fpga\program.bat <board>` only loads an existing bitstream again. Rebuild after any change to `rtl/`, `fpga/`
     or the `.mem` files.
4. **Controls** (INT8 and INT4 are both in one bitstream):
   - **SW7–SW0**: test clip 0–199. **SW15**: down = INT8, up = INT4. **SW14**: fault test (see below).
   - **BTNC**: run one clip. The right digits show the word (YES / nO / On / OFF / LEFt / rIGHt), the left digits
     the clip.
   - **LEDs:**
     - LED[2:0] = word, LED[6:4] = true word;
     - LED12 = correct; LED13 = class and all 6 scores match Python;
     - LED11 = SW14 is up, LED14 = busy;
     - LED16 (RGB): green = matches Python, red = differs, blue = running.
5. **Self-check: is the board doing the same math as Python?** BTNU runs all 200 clips. For each one it compares the
   class **and all 6 output scores** with the Python integer model.

   | Do | Expect |
   |---|---|
   | SW15 down, BTNU | green LED16, `PASS 176` (every clip matches Python; 176 words correct) |
   | SW15 up, BTNU | green LED16, `PASS 177` |
   | SW14 up, SW15 down, BTNU, then SW14 down again | red LED16, `F000 199`: the fault test corrupted clip 0, so the checker must fail there |

   - `F<nnn> <mmm>`: clip `nnn` was the first to differ from Python, and `mmm` clips matched.
   - `Err ----`: the board's golden data failed its checksum, which means a `.mem` file was missing or damaged when the
     bitstream was built. Run `python fpga/gen_fpga_mem.py --check`, regenerate if it says so, and rebuild.
6. **Live words from your voice** (PC microphone → PC computes MFCC → board recognizes the word):
   ```bat
   pip install -r fpga/requirements-live.txt
   python fpga/kws_live.py --selftest
   python fpga/kws_live.py --mic
   ```
   - `--selftest` sends the 200 test clips through the UART and checks every reply against Python. Expect
     `SELFTEST PASSED` with 200/200 for INT8 and INT4. Run this first: it proves the cable, the port and the board.
   - `--mic`: press Enter and say one word. The board shows `LI <word>`, and the PC prints the board's answer, the 6
     scores and whether the Python model gives the same answer.
   - Options: `--prec int4`, `--save recordings` (keeps each recording as a .wav), `--wav file.wav`, `--port COM5`.
   - Live accuracy will be lower than the 86.7 % test accuracy: a different microphone, room noise, and the
     word's position in the 1-second window. Speak clearly, close to the microphone, one word per recording.
   - `--mock` runs the same script with a software model instead of the board (no hardware needed).
7. To keep new numbers for the report, commit `results/fpga/` and write down what the board showed in a progress log.

## 5. Daily workflow (both partners)

```bash
git pull                              # 1. ALWAYS start here (on every machine)
# 2. do the work (with Claude); run the relevant checks:
./sim/run_sim.sh int8                 #    RTL changed?   must say TEST PASSED (also int4, fpga)
                                      #    (Windows: .\sim\run_sim.ps1 int8)
# crosby3 only, in flow/tsmc18:  rc -f syn_int8.g ; innovus -files pnr_int8.tcl
# then ./save_results.sh int8         #    copy reports into results/int8/
# 3. write/update docs/progress/<date>-<milestone>.md (Claude does this)
git add -A
git status                            # 4. check: no work/ , logs, .enc.dat, .bit
git commit -m "rtl: describe the change"
git push                              # 5. partner pulls to continue
```
- **Split the work so you rarely edit the same file at the same time.** Suggested split:

  | Week | Partner A | Partner B |
  |------|-----------|-----------|
  | 1 | Train + quantize (`python/`), export weights | Get crosby3 Git and the library paths working, first Genus run with synthetic weights |
  | 2 | Testbench and verification against Python | RTL refinements (`rtl/`), FPGA build |
  | 3 | Synthesis sweeps INT8/INT4 (`flow/syn`) | Innovus P&R (`flow/pnr`), FPGA demo |
  | 4 | Report (`docs/report/`) | Slides (`docs/slides/`), final results tables |
- For bigger changes, use a branch: `git switch -c yourname/feature`, push it, and merge it on GitHub with a Pull Request.
- **Merge conflicts:** run `git status` to see the conflicted files, edit the `<<<<<<< ======= >>>>>>>` blocks,
  then `git add <file>` and `git rebase --continue`. You can also ask Claude to resolve them.

## 6. Using Claude across machines

- Open the repo folder in Claude Code on whichever laptop you're using. Claude reads `CLAUDE.md`
  automatically, so it knows the project, the rules and the progress-log requirement.
- Start a session with: *"git pull, read the latest file in docs/progress, and continue."*
- When something works, say *"log this milestone"*. Claude then writes `docs/progress/...`,
  updates this file if setup changed, and commits.
- The Cadence tools are only on crosby3. Paste errors or reports from crosby3 to Claude,
  or better, commit `results/` and let Claude read them after `git pull`.

## 7. Troubleshooting

| Symptom | Fix |
|---------|-----|
| `kws_live.py`: "No board answered" | Program the bitstream from this branch (an older one has no UART), use the PROG/UART micro-USB port, close any serial terminal, or pass `--port COMx` (Device Manager → Ports) |
| BTNU shows `Err ----` | A `.mem` file was missing or stale when the bitstream was built: `python fpga/gen_fpga_mem.py --check`, then rebuild |
| `--mic` hears nothing (macOS) | Allow microphone access for Terminal in System Settings → Privacy & Security |
| `rc: command not found` / `innovus: command not found` | You forgot `source /home/opt2/setmyenv` in this terminal |
| RC/Innovus can't find `slow.lib` or `all.lef` | Copy the tsmc18 files into `flow/tsmc18/` (§3) |
| Cadence GUI doesn't appear (Mac) | Install XQuartz, reconnect with `ssh -Y`, run `echo $DISPLAY` (must not be empty) |
| `No weights/int8` | Run `python python/export_hw.py` (needs a trained model in `results/python/`) |
| Script fails with `\r` / `bad interpreter` | Line endings were changed on Windows. `.gitattributes` prevents this. To repair, commit or stash your work first, then run `git rm --cached -r . && git reset --hard` (this discards uncommitted changes) |
| `vivado` not recognized (Windows) | Run `settings64.bat` from the Vivado install folder first |
| Vivado sim fails with "Spawn failed" from an AI agent shell | Use `sim\run_sim.ps1`, which clears `NoDefaultCurrentDirectoryInExePath` |
| Board not found when programming | Use the USB-PROG port, power switch ON, close other Vivado Hardware Manager windows |
| push rejected (`fetch first`) | Run `git pull`, then `git push` again |
