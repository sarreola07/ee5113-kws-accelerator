"""MFCC feature extraction written with numpy only (no librosa needed).

Pipeline per 1-second clip:
  40 ms Hamming frames (25 frames) -> |FFT|^2 -> 40 mel filters -> log -> DCT -> 10 coefficients
Result: 25 x 10 = 250 numbers, flattened frame-major: feature[t * N_MFCC + c].
"""
import numpy as np

import config as C


def _hz_to_mel(f):
    return 2595.0 * np.log10(1.0 + f / 700.0)


def _mel_to_hz(m):
    return 700.0 * (10.0 ** (m / 2595.0) - 1.0)


def _mel_filterbank():
    mel_points = np.linspace(_hz_to_mel(C.F_MIN), _hz_to_mel(C.F_MAX), C.N_MELS + 2)
    hz_points = _mel_to_hz(mel_points)
    freqs = np.fft.rfftfreq(C.N_FFT, d=1.0 / C.SAMPLE_RATE)
    bank = np.zeros((C.N_MELS, freqs.size))
    for m in range(C.N_MELS):
        lo, mid, hi = hz_points[m:m + 3]
        rising = (freqs - lo) / (mid - lo)
        falling = (hi - freqs) / (hi - mid)
        bank[m] = np.clip(np.minimum(rising, falling), 0.0, None)
    return bank


def _dct_matrix():
    """Orthonormal DCT-II, keeping the first N_MFCC coefficients."""
    k = np.arange(C.N_MFCC)[:, None]
    n = np.arange(C.N_MELS)[None, :]
    d = np.cos(np.pi / C.N_MELS * (n + 0.5) * k) * np.sqrt(2.0 / C.N_MELS)
    d[0] /= np.sqrt(2.0)
    return d


_WINDOW = np.hamming(C.FRAME_LEN)
_MEL_BANK = _mel_filterbank()
_DCT = _dct_matrix()
_FRAME_IDX = np.arange(C.FRAME_LEN)[None, :] + C.FRAME_HOP * np.arange(C.N_FRAMES)[:, None]


def mfcc(audio):
    """audio: (N, CLIP_SAMPLES) floats in [-1, 1]  ->  (N, N_INPUTS) float32 features."""
    audio = np.atleast_2d(np.asarray(audio, dtype=np.float64))
    frames = audio[:, _FRAME_IDX] * _WINDOW                  # (N, T, FRAME_LEN)
    power = np.abs(np.fft.rfft(frames, n=C.N_FFT)) ** 2       # (N, T, N_FFT/2 + 1)
    log_mel = np.log(power @ _MEL_BANK.T + 1e-6)              # (N, T, N_MELS)
    coeffs = log_mel @ _DCT.T                                 # (N, T, N_MFCC)
    return coeffs.reshape(len(audio), -1).astype(np.float32)
