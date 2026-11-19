"""MFCC audio features in plain NumPy.

This is the computation torchaudio.transforms.MFCC performs with
    sample_rate=16000, n_mfcc=10, melkwargs={"n_fft": 400, "hop_length": 160, "n_mels": 40}
followed by average pooling over time and a flatten. Step by step, for one
1-second clip (16000 samples):

  1. Frames:   pad 200 samples on each side by reflection, then cut 101 frames of
               400 samples (25 ms), one every 160 samples (10 ms).
  2. Window:   multiply each frame by a periodic Hann window (smooth edges).
  3. Spectrum: real FFT -> 201 frequency bins, 40 Hz apart; keep the power |X|^2.
  4. Mel:      40 triangular filters on the HTK mel scale (0-8000 Hz) sum the
               power into 40 bands, spaced the way the ear resolves pitch.
  5. Log:      10*log10 (decibels), clamped to at most 80 dB below the clip's peak.
  6. DCT:      an orthonormal DCT-II of the 40 band energies; keep the first 10
               coefficients (the smooth shape of the spectrum) -> 101 x 10 MFCCs.
  7. Pool:     average the 101 frames down to 25 (5 frames each, overlapping by 1),
               the same windows as torch.nn.functional.adaptive_avg_pool1d.
  8. Flatten:  frame-major, index = frame*10 + coefficient -> 250 numbers.

Training standardizes these 250 numbers (train.py); quantize_export.py turns
them into the integers the hardware sees.
"""
import os
import sys
import wave

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kws_common import (AMIN, CLIP_SAMPLES, F_MAX, F_MIN, HOP, N_FFT, N_FRAMES,  # noqa: E402
                        N_IN, N_MELS, N_MFCC, N_STFT_FRAMES, SAMPLE_RATE, TOP_DB)

N_BINS = N_FFT // 2 + 1          # 201 FFT bins, SAMPLE_RATE / N_FFT = 40 Hz apart


# ------------------------------------------------------------- building blocks ---
def hz_to_mel(f):
    """HTK mel scale."""
    return 2595.0 * np.log10(1.0 + np.asarray(f, dtype=np.float64) / 700.0)


def mel_to_hz(m):
    return 700.0 * (10.0 ** (np.asarray(m, dtype=np.float64) / 2595.0) - 1.0)


def hann_periodic(n=N_FFT):
    """Periodic Hann window (torch.hann_window default), not the symmetric np.hanning."""
    k = np.arange(n, dtype=np.float64)
    return 0.5 - 0.5 * np.cos(2.0 * np.pi * k / n)


def mel_filterbank(n_fft=N_FFT, n_mels=N_MELS, sr=SAMPLE_RATE, f_min=F_MIN, f_max=F_MAX):
    """(n_bins, n_mels) matrix of unnormalized triangles with peak 1 (torchaudio norm=None)."""
    all_freqs = np.linspace(0.0, sr // 2, n_fft // 2 + 1)
    f_pts = mel_to_hz(np.linspace(hz_to_mel(f_min), hz_to_mel(f_max), n_mels + 2))
    f_diff = f_pts[1:] - f_pts[:-1]
    slopes = f_pts[None, :] - all_freqs[:, None]
    down = -slopes[:, :-2] / f_diff[:-1]
    up = slopes[:, 2:] / f_diff[1:]
    return np.maximum(0.0, np.minimum(down, up))


def dct_matrix(n_mfcc=N_MFCC, n_mels=N_MELS):
    """(n_mfcc, n_mels) orthonormal DCT-II rows (torchaudio create_dct, norm='ortho')."""
    n = np.arange(n_mels, dtype=np.float64)
    k = np.arange(n_mfcc, dtype=np.float64)[:, None]
    d = np.cos(np.pi / n_mels * (n + 0.5) * k)
    d[0] *= 1.0 / np.sqrt(2.0)
    return d * np.sqrt(2.0 / n_mels)


_WINDOW = hann_periodic()
_FBANK = mel_filterbank()
_DCT = dct_matrix()


def frames(x):
    """(101, 400) overlapping frames of a centered, reflect-padded clip."""
    xp = np.pad(np.asarray(x, dtype=np.float64), (N_FFT // 2, N_FFT // 2), mode="reflect")
    n = 1 + (len(xp) - N_FFT) // HOP
    idx = HOP * np.arange(n)[:, None] + np.arange(N_FFT)[None, :]
    return xp[idx]


def power_spectrogram(x):
    """(frames, 201) power spectrum."""
    return np.abs(np.fft.rfft(frames(x) * _WINDOW, axis=1)) ** 2


def log_mel(power):
    """(frames, 40) mel band energies in dB, floored at 80 dB below the clip's peak."""
    db = 10.0 * np.log10(np.maximum(power @ _FBANK, AMIN))
    return np.maximum(db, db.max() - TOP_DB)


def mfcc(x):
    """(frames, 10) MFCCs of a float clip in [-1, 1)."""
    return log_mel(power_spectrogram(x)) @ _DCT.T


def pool_bounds(n_in=N_STFT_FRAMES, n_out=N_FRAMES):
    """[start, end) windows of torch adaptive_avg_pool1d."""
    return [((i * n_in) // n_out, -((-(i + 1) * n_in) // n_out)) for i in range(n_out)]


def adaptive_avg_pool(f, n_out=N_FRAMES):
    return np.stack([f[s:e].mean(axis=0) for s, e in pool_bounds(len(f), n_out)])


def clip_features(pcm):
    """int16 samples of one clip -> (250,) float32 feature vector."""
    x = np.asarray(pcm, dtype=np.float64) / 32768.0
    if len(x) < CLIP_SAMPLES:
        x = np.pad(x, (0, CLIP_SAMPLES - len(x)))       # short clips: zeros at the end
    x = x[:CLIP_SAMPLES]
    feats = adaptive_avg_pool(mfcc(x)).reshape(-1)       # frame-major: frame*10 + coeff
    assert feats.shape == (N_IN,)
    return feats.astype(np.float32)


# --------------------------------------------------------------------- files ---
def read_wav(path):
    """Samples of a mono, 16-bit, 16 kHz PCM WAV file as int16."""
    with wave.open(path, "rb") as w:
        if (w.getnchannels(), w.getsampwidth(), w.getframerate()) != (1, 2, SAMPLE_RATE):
            raise ValueError(f"{path}: expected mono 16-bit {SAMPLE_RATE} Hz, got "
                             f"{w.getnchannels()} ch, {8 * w.getsampwidth()} bit, {w.getframerate()} Hz")
        data = w.readframes(w.getnframes())
    return np.frombuffer(data, dtype="<i2")


def file_features(path):
    return clip_features(read_wav(path))


def features_from_files(paths, workers=1, label=""):
    """(len(paths), 250) features; workers > 1 uses that many processes."""
    out = np.zeros((len(paths), N_IN), dtype=np.float32)
    if workers > 1 and len(paths) > 256:
        from concurrent.futures import ProcessPoolExecutor
        with ProcessPoolExecutor(max_workers=workers) as pool:
            for i, f in enumerate(pool.map(file_features, paths, chunksize=64)):
                out[i] = f
                _progress(i + 1, len(paths), label)
    else:
        for i, p in enumerate(paths):
            out[i] = file_features(p)
            _progress(i + 1, len(paths), label)
    return out


def _progress(done, total, label):
    if done == total or done % 2000 == 0:
        print(f"  {label} features: {done}/{total}", flush=True)
