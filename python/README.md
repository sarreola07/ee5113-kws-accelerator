# Low-Precision Keyword Spotting Accelerator: Python part

This is the software half of the EE5113 project. It trains a small neural network that
recognizes 6 spoken words, converts it to INT8 and INT4, and exports the weights and
test vectors that the Verilog accelerator loads with `$readmemh`.

## Setup (once)

```bash
python -m pip install -r python/requirements.txt     # from the repo root
```

## Quick test (about 1 minute)

```bash
python python/quick_test.py
```
Trains on a small sample (200 clips per word) and builds the INT8 and INT4 models. It should
end with `OK: the pipeline works.` and roughly 65% accuracy. The full run below reaches about
86%. The quick test does not change any saved results.

## Full run (from the repo root)

```bash
python python/prepare_data.py
```
Downloads Google Speech Commands v0.02 (~2.3 GB stream, only the chosen words are kept,
about 700 MB) and computes MFCC features into `python/data/features.npz` (git-ignored).
It also writes the small `results/python/feature_norm.npz` (feature mean/std, committed), which
`fpga/mic_demo.py` uses to normalize words from the PC microphone the same way.

```bash
python python/train.py
```
Trains the FP32 model, then makes INT8 and INT4 versions two ways (PTQ and QAT) and
prints an accuracy table. Writes `results/python/`.

```bash
python python/export_hw.py
```
Writes `weights/int8/` and `weights/int4/` for the Verilog design and testbench.

```bash
python python/make_figures.py
```
Optional. Writes slide images to `results/python/figures/`: charts, plus terminal-style images of each
step's console output. The output is read from `results/python/logs/`, so save it there when you
run the steps, e.g. `python -u python/train.py | tee results/python/logs/train.txt`.

## Results (6 words, 2430 test clips)

| Model | Test accuracy | Weight memory |
|---|---|---|
| FP32 | 86.0% | 32 KB |
| INT8 (QAT) | 86.7% | 8 KB |
| INT4 (PTQ, plain rounding) | 83.7% | 4 KB |
| INT4 (QAT) | 85.1% | 4 KB |

INT8 loses nothing. INT4 loses about 1 point after quantization-aware training (QAT) and
about 2 points with plain rounding (PTQ). The INT accuracies come from the bit-exact
integer model, so the hardware should reproduce them exactly.

To check that the code runs without downloading anything, use fake tone data:
```bash
python python/prepare_data.py --synthetic
```
```bash
python python/train.py --features python/data/features_synthetic.npz
```

## Files

| File | What it does |
|---|---|
| `python/config.py` | All settings: words, MFCC sizes, hidden layer size, bit widths, epochs |
| `python/mfcc.py` | MFCC feature extraction (numpy only) |
| `python/prepare_data.py` | Step 1: download + features |
| `python/quant.py` | **Bit-exact integer reference model** that the hardware must match |
| `python/train.py` | Step 2: float training, PTQ and QAT for each bit width |
| `python/export_hw.py` | Step 3: `.mem` and `.vh` files for Verilog |
| `python/make_figures.py` | Step 4 (optional): slide images in `results/python/figures/` |
| `results/python/results.csv` | Accuracy and memory size per model (for the report table) |
| `results/python/confusion_*.csv` | Confusion matrix per model |
| `results/python/feature_norm.npz` | Feature mean/std + typical loudness, for live audio (`fpga/mic_demo.py`) |

## Network

```
250 MFCC features (25 frames x 10 coefficients, 40 ms frames)
   -> fully connected 250 x 32 -> ReLU -> requantize (right shift)
   -> fully connected 32 x 6 -> argmax -> word index
```
Words: `0=yes 1=no 2=on 3=off 4=left 5=right` (change `WORDS` in `config.py`).
8192 weights in total, so the weight memory is 8 KB at INT8 and 4 KB at INT4.

## What the hardware must compute (bit exact)

`BW` is the bit width (8 or 4) and `QMAX = 2^(BW-1) - 1` (127 or 7). All values are signed.

1. The input vector `x[0..249]` arrives already quantized (BW bits each).
2. Layer 1: `acc[j] = b1[j] + sum_i W1[j][i] * x[i]` in an `ACC_W`-bit accumulator.
   Start the accumulator at the bias, then do one MAC per clock.
3. ReLU: `r = max(acc, 0)`.
4. Requantize: `h[j] = min((r + 2^(SHIFT-1)) >>> SHIFT, QMAX)`. This is round-half-up then saturate.
5. Layer 2: `out[k] = b2[k] + sum_j W2[k][j] * h[j]`. Same MAC unit, no ReLU or shift.
6. Argmax: the index of the largest `out[k]`. Use a strict `>` compare so the lowest index
   wins on a tie, the same as numpy.

`ACC_W`, `SHIFT` and the memory layout are in `weights/int*/kws_params.vh`.
`test_hidden.mem` and `test_logits.mem` hold the expected intermediate values, so a mismatch
can be traced to the exact layer and neuron.

With one MAC unit, an inference takes about 8192 cycles plus overhead. That is 82 µs at
100 MHz, far faster than the 1 second of audio it processes.
