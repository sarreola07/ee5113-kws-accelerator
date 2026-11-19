# Testbench upgrade, INT6 export and a NumPy training pipeline

- **Date:** 2026-11-19
- **Author:** sarreola07
- **Branch / commit:** main (three commits: `tb:`, `python:` export, `python:` training pipeline)
- **Machine(s):** cloud Linux session → GitHub. Next: the lab PC (training) and crosby3.

## What was done
- **Testbench (`tb/kws_tb.v`, `sim/run_sim.sh`):**
  - the clock period is settable with `TB_CLK_NS`;
  - inputs change 0.2 T after the clock edge and outputs are sampled at 0.8 T, matching `constraints.sdc`;
  - a per-clip watchdog, plus an X check on `class_out`;
  - `VCD=1` dumps only the accelerator, for exactly one inference after a warm-up clip, and prints a
    `VCD_WINDOW` line for power tools;
  - an `SDF` hook for gate-level runs;
  - the FPGA test now runs in its own folder.
- **Exporter (`python/quantize_export.py`):**
  - INT6 added as a third precision (INT8 vs INT4 stays the headline);
  - accuracy, validation accuracy, INT-vs-float agreement and a confusion matrix are now computed on the
    **full test split**;
  - the 50 simulation clips and the 16 FPGA clips cycle through all 6 words. Before, they would have come
    from one or two words, because the first N clips of a sorted list were taken.
- **Training rebuilt in NumPy:** the old `train.py` used torchaudio, which crashes on current versions
  because torchcodec is missing.
  - `python/kws_data.py` streams Speech Commands v0.02 over HTTPS, keeps only the 6 words and the official
    split lists, and checks the MD5;
  - `python/kws_features.py` computes the same MFCC as torchaudio's defaults;
  - `python/train.py` trains the 250→32→6 MLP with Adam and early stopping on the validation split;
  - `python/requirements.txt` is now **numpy only**;
  - 15 unit tests: MFCC properties, a gradient check, training on test data, exporter determinism, and
    a check that every committed `weights/` folder matches its `golden.mem`.

## How to run training yourself (lab PC or any laptop)
```bash
# where: the lab PC (log in with: ssh lab), inside tmux so it survives a dropped connection
tmux new -s kws
cd ~/work && git clone https://github.com/sarreola07/ee5113-kws-accelerator.git   # or: git pull
cd ee5113-kws-accelerator
python3 -m venv .venv && source .venv/bin/activate      # no venv/pip? see Troubleshooting below
pip install -r python/requirements.txt
python3 -m unittest discover -s python -p "test_*.py"   # expect: Ran 15 tests ... OK
python3 python/train.py --workers 8                      # download + features + training
python3 python/quantize_export.py                        # writes weights/int8, int6, int4
```
Then check that the hardware still matches. Use whichever machine has a simulator:
`./sim/run_sim.sh int8 iverilog` on a laptop, or `./sim/run_sim.sh int8 xcelium` on crosby3. Repeat for
int6 and int4, and also run `./sim/run_sim.sh int8 fpga`. Every run must print `TEST PASSED`.

Finally:
1. Commit `weights/` together with a new progress log containing the accuracies from
   `weights/*/summary.json`.
2. Commit as yourself; see the "Authorship" section of CLAUDE.md.
3. Push.

**What to expect:**
- The first run streams about 2.4 GB and keeps about 0.75 GB in `python/data/` (git-ignored).
- Feature extraction is the slow part; `--workers` uses more CPU cores.
- Training prints one line per epoch and stops on its own when validation accuracy stops improving.
- The GPU is not used: this is a small model.

**Troubleshooting:**
- `python3 -m venv` fails with "ensurepip is not available" (no sudo on the lab PC): install `uv` in your
  home folder and use it instead:
  ```bash
  curl -LsSf https://astral.sh/uv/install.sh | sh
  uv venv && source .venv/bin/activate
  uv pip install -r python/requirements.txt
  ```
- **Download interrupted:** run the same command again. Files already unpacked are skipped. Or download
  the archive yourself with `curl -C - -O <URL from python/kws_data.py>` and run
  `python3 python/train.py --tar speech_commands_v0.02.tar.gz`.
- **Accuracy far below what you expect, or settings changed:** run `python3 python/train.py --rebuild-features`.

## Files added / changed
| File | What it is | Used by |
|------|-----------|---------|
| `tb/kws_tb.v`, `sim/run_sim.sh` | testbench and runner (new timing, VCD window) | laptop / crosby3 |
| `python/kws_common.py` | PRECISIONS with int6, MFCC settings (`FEATURE_CFG`) | all Python |
| `python/quantize_export.py` | full-split accuracy, round-robin clips, new options | after training |
| `python/kws_data.py`, `kws_features.py`, `train.py` | NumPy download, features, training | lab PC / laptop |
| `python/test_*.py` | unit tests | everyone, CI later |
| `weights/int6/*`, `weights/int8|int4/summary.json` | synthetic placeholder weights; the int8/int4 hardware files are byte-identical to before | sims, flows, FPGA |

## Results (all verified in the cloud session; the weights are still SYNTHETIC placeholders)
| Check | INT8 | INT6 | INT4 |
|-------|------|------|------|
| RTL vs Python golden (50 clips) | 50/50 | 50/50 | 50/50 |
| FPGA board test | pass | pass | pass |
| Cycles per inference | 8,312 | 8,312 | 8,312 |
| One-inference VCD window | 8,563 cycles | — | — |

- Unit tests: 15/15 pass.
- A smoke test on a tiny fake dataset (tones in WAV files, packed like the real archive) ran download → features
  → training → export end to end.

## Not verified yet
- **The real download and training run.** They have never been run on the real dataset. You are doing that
  run. If anything fails, paste the error into Claude.
- None of the planned flow work exists yet: gate-level simulation, the power/energy steps, the Fmax sweep
  and the Cadence script fixes found by the research. This also covers `docs/TRAINING.md` and the GitHub CI
  (see Next steps).

## Next steps
- [ ] You: train on the lab PC (above), export, run the sims, commit the real weights with a progress log.
- [ ] `docs/TRAINING.md`: a step-by-step lesson explaining MFCC, the network, training and quantization.
- [ ] Flow upgrades:
  - Cadence script fixes: the `addFiller` cell list (it would stop the P&R run), the GDS map path, the top
    routing layer, the pin layer, `-batch`;
  - `write_sdf`;
  - `./flow/run.sh gls|power`, `flow/energy.py`, `flow/sweep.sh`.
- [ ] GitHub Actions CI running the unit tests and simulations on every push.
