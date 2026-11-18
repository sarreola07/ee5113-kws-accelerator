# SETUP — environment and how to load the files

> **This is the living setup guide.** If you follow it from top to bottom on a
> fresh machine, you should end up able to run every part of the project.
> Whenever a step changes, it is updated here, in the same commit as the change
> (see `CLAUDE.md`). Last updated: **2026-11-18** (initial repo setup).

## 0. What runs where

| Task | Machine | Tools |
|------|---------|-------|
| Edit code and docs, use Claude | any laptop (Mac or Windows) | Git, VS Code (optional), Claude Code |
| Train and quantize the network | any laptop | Python 3.10+, PyTorch, torchaudio |
| RTL simulation (quick check) | any laptop, or crosby3 | Icarus Verilog (laptop) / Xcelium (crosby3) |
| Synthesis + place & route | **crosby3.utsarr.net** only | Cadence Genus + Innovus, gpdk045 |
| FPGA build + program Nexys 4 | **Windows** laptop (or Linux) | Xilinx Vivado (not available for macOS) |

GitHub (`https://github.com/sarreola07/ee5113-kws-accelerator`, private) is the
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

Quick check (no dataset needed), which regenerates placeholder weights and simulates:
```bash
python python/quantize_export.py --synthetic
./sim/run_sim.sh int8 iverilog     # expect: TEST PASSED
```
> The synthetic command overwrites `weights/`. If real trained weights are
> already committed, don't commit the synthetic ones. Run `git checkout weights/` to restore them.

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
which genus innovus xrun           # all three should print a path
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

### Point the flow at the 45 nm libraries (first person to do this commits it)
```bash
./flow/find_libs.sh                 # lists candidate .lib / .lef / qrc / map files
nano flow/config.tcl                # fix LIB_SLOW, LIB_FAST, LEF_FILES, QRC_TECH, GDS_MAP
git commit -am "flow: gpdk045 paths on crosby3" && git push
```

## 4. FPGA: Nexys 4 (Windows + Vivado)

1. **Identify your board revision.** The label is printed on the board:
   - **Nexys 4 DDR** or **Nexys A7** → use `nexys4ddr`
   - plain **Nexys 4** (no "DDR") → use `nexys4`

   The pin files in `fpga/constraints/` were copied from Digilent's official master XDC files.
2. Plug in the board's USB-PROG port and power it on.
3. Open a **Command Prompt** in the repo folder. If `vivado` isn't found, first run
   `C:\Xilinx\Vivado\<version>\settings64.bat`. Then:
   ```bat
   fpga\build.bat int8 nexys4ddr program
   ```
   This writes the bitstream and reports to `fpga\work\int8_nexys4ddr\`. Check that `timing.rpt` shows no negative slack.
4. On the board:
   1. Set **SW3–SW0** to pick a stored clip (0–15).
   2. Press **BTNC**.
   3. The display shows the recognized word (YES / no / on / OFF / UP / dn). The leftmost digit shows the clip number.

   The true word for each clip is in `weights/int8/summary.json` → `fpga_clip_labels`.
5. To keep the numbers for the report, copy `utilization.rpt`, `timing.rpt` and `power.rpt`
   into `results/fpga/<prec>/` and commit them.

## 5. Daily workflow (both partners)

```bash
git pull                              # 1. ALWAYS start here (on every machine)
# 2. do the work (with Claude); run the relevant checks:
./sim/run_sim.sh int8                 #    RTL changed?   must say TEST PASSED (also int4)
./flow/run.sh all int8                #    crosby3 only:  Genus + Innovus
./flow/run.sh save int8               #    copy reports into results/int8/
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
| `genus: command not found` | You forgot `source /home/opt2/setmyenv` in this terminal |
| `**ERROR** missing file` from the flow | Fix the paths in `flow/config.tcl` (§3) |
| Cadence GUI doesn't appear (Mac) | Install XQuartz, reconnect with `ssh -Y`, run `echo $DISPLAY` (must not be empty) |
| `No weights/int8` | Run `python python/quantize_export.py` (or `--synthetic`) and commit `weights/` |
| Script fails with `\r` / `bad interpreter` | Line endings were changed on Windows. `.gitattributes` prevents this. To repair, commit or stash your work first, then run `git rm --cached -r . && git reset --hard` (this discards uncommitted changes) |
| `vivado` not recognized (Windows) | Run `settings64.bat` from the Vivado install folder first |
| Board not found when programming | Use the USB-PROG port, power switch ON, close other Vivado Hardware Manager windows |
| push rejected (`fetch first`) | Run `git pull`, then `git push` again |
