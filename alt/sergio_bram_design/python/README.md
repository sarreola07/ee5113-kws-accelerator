# python/ — dataset, features, training, quantization and the golden model

Everything here needs only **Python 3.8+ and NumPy** (`pip install -r python/requirements.txt`).
Run it on a laptop or a Linux lab machine. No GPU is needed.

| Step | Command | Output (git status) |
|------|---------|---------------------|
| 0. Check the code | `python -m unittest discover -s python -p "test_*.py"` | `Ran 15 tests ... OK` |
| 1. Download + features + train | `python python/train.py --workers 8` | `python/data/`, `python/checkpoints/model.npz` (ignored) |
| 2. Quantize + export INT8/INT6/INT4 | `python python/quantize_export.py` | `weights/int8`, `int6`, `int4` (**commit these**) |
| 3. Check hardware == Python | `./sim/run_sim.sh int8` (also int6, int4, and `int8 fpga`) | `TEST PASSED` |

| File | What it does |
|------|--------------|
| `kws_common.py` | Network sizes, words, precisions, MFCC settings, and the bit-exact integer golden model `int_forward` |
| `kws_data.py` | Streams Speech Commands v0.02 (2.4 GB read, about 0.75 GB kept) and checks the MD5; `--tar` uses a local archive |
| `kws_features.py` | MFCC in NumPy, the same computation as torchaudio's MFCC defaults; 250 numbers per 1 s clip |
| `train.py` | NumPy MLP 250→32→6 trained with Adam and early stopping on the validation split |
| `quantize_export.py` | Post-training quantization and export for the hardware; accuracy on the full test split goes into `summary.json` |
| `test_*.py` | Unit tests that need no dataset |

- `--synthetic` on step 2 skips step 1 and uses random weights. Use it only for hardware testing, never for results.
- The network size and word list are in `kws_common.py`. If you change them, retrain, re-export and re-run every
  simulation. The 7-segment word table in `fpga/fpga_top.v` follows the `WORDS` order.
- Dataset: P. Warden, "Speech Commands: A Dataset for Limited-Vocabulary Speech Recognition", 2018, CC BY 4.0.
