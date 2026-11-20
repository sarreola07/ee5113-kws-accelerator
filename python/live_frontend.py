"""Turns 1 second of audio into the accelerator's integer inputs, exactly like
the training data (used by fpga/kws_live.py and python/export_frontend.py).

    audio (16 kHz, float in [-1, 1]) -> mfcc() -> (x - mean) / std -> quantize(s_x)

mean / std / s_x come from weights/frontend.npz (python/export_frontend.py).
"""
import json

import numpy as np

import config as C
import quant as Q
from mfcc import mfcc

FRONTEND_FILE = C.HW_DIR / "frontend.npz"


def load(path=FRONTEND_FILE):
    """{'mean', 'std', 'words', 's_x': {bits: scale}, 'cfg'} from frontend.npz."""
    d = np.load(path)
    cfg = json.loads(str(d["cfg"]))
    for key in ("sample_rate", "clip_samples", "frame_len", "frame_hop", "n_fft", "n_mels", "n_mfcc"):
        if cfg[key] != getattr(C, key.upper()):
            raise ValueError(f"{path} was made with {key}={cfg[key]}, config.py has {getattr(C, key.upper())}; "
                             "run python/export_frontend.py again")
    return {"mean": d["mean"], "std": d["std"], "words": [str(w) for w in d["words"]],
            "s_x": {int(b): float(s) for b, s in zip(d["bits"], d["s_x"])}, "cfg": cfg}


def to_inputs(audio, fe, bits):
    """One clip of CLIP_SAMPLES floats -> (N_INPUTS,) int64 inputs for the hardware."""
    audio = np.asarray(audio, dtype=np.float32)
    clip = np.zeros(C.CLIP_SAMPLES, np.float32)
    n = min(len(audio), C.CLIP_SAMPLES)
    clip[:n] = audio[:n]
    feats = mfcc(clip[None, :])                                  # (1, 250) float32
    x = ((feats - fe["mean"]) / fe["std"]).astype(np.float32)   # same as prepare_data.py
    return Q.quantize(x, fe["s_x"][bits], bits)[0]


def loudest_window(audio, length=C.CLIP_SAMPLES, hop=160):
    """The `length`-sample part of a longer recording with the most energy
    (centres the spoken word the way the 1-second dataset clips are)."""
    audio = np.asarray(audio, dtype=np.float32)
    if len(audio) <= length:
        return audio
    e = np.concatenate([[0.0], np.cumsum(audio.astype(np.float64) ** 2)])
    starts = np.arange(0, len(audio) - length + 1, hop)
    best = starts[np.argmax(e[starts + length] - e[starts])]
    return audio[best:best + length]
