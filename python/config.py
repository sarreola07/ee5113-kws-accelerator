"""Project settings shared by every script. Change the words or network size here."""
from pathlib import Path

# ---------------------------------------------------------------- folders
ROOT = Path(__file__).resolve().parent.parent   # repo root
DATA_DIR = ROOT / "python" / "data"             # dataset + features (git-ignored)
SPEECH_DIR = DATA_DIR / "speech_commands"      # extracted .wav files
FEATURES_FILE = DATA_DIR / "features.npz"      # MFCC features (output of prepare_data.py)
RESULTS_DIR = ROOT / "results" / "python"      # trained models, accuracy tables, figures
HW_DIR = ROOT / "weights"                      # .mem / .vh files for the Verilog design

DATASET_URL = ("https://storage.googleapis.com/download.tensorflow.org/"
               "data/speech_commands_v0.02.tar.gz")

# ---------------------------------------------------------------- keywords
# 4 to 6 words from Google Speech Commands. Class index = position in this list.
WORDS = ["yes", "no", "on", "off", "left", "right"]

# ---------------------------------------------------------------- MFCC front end (software)
SAMPLE_RATE = 16000
CLIP_SAMPLES = 16000            # 1 second clips
FRAME_LEN = 640                 # 40 ms analysis window
FRAME_HOP = 640                 # 40 ms hop  -> 25 frames per clip
N_FFT = 1024
N_MELS = 40
N_MFCC = 10
F_MIN, F_MAX = 20.0, 7600.0
N_FRAMES = 1 + (CLIP_SAMPLES - FRAME_LEN) // FRAME_HOP     # 25
N_INPUTS = N_FRAMES * N_MFCC                               # 250

# ---------------------------------------------------------------- network
# N_INPUTS -> N_HIDDEN (ReLU) -> len(WORDS) -> argmax
# Weight count = 250*32 + 32*6 = 8192  (8 KB at INT8, 4 KB at INT4)
N_HIDDEN = 32

# Precisions to build hardware for
BIT_WIDTHS = [8, 4]

# ---------------------------------------------------------------- training
SEED = 1234
FLOAT_EPOCHS = 60
QAT_EPOCHS = 30                 # quantization-aware fine-tuning per bit width
BATCH_SIZE = 128
FLOAT_LR = 1e-3
QAT_LR = 2e-4
WEIGHT_DECAY = 1e-4
DROPOUT = 0.1

# Number of test clips exported for the Verilog testbench
N_HW_TEST_VECTORS = 200
