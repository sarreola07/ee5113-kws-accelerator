"""Unit tests for the NumPy MFCC (no dataset needed).

    python -m unittest discover -s python -p "test_*.py"
"""
import os
import tempfile
import unittest
import wave

import numpy as np

import kws_features as kf
from kws_common import CLIP_SAMPLES, N_FRAMES, N_IN, N_MELS, N_MFCC, N_STFT_FRAMES, SAMPLE_RATE


class TestBuildingBlocks(unittest.TestCase):
    def test_pool_bounds_match_torch_adaptive_pool(self):
        self.assertEqual(kf.pool_bounds(101, 25), [(4 * i, 4 * i + 5) for i in range(25)])

    def test_hann_window_is_periodic(self):
        w = kf.hann_periodic(400)
        self.assertEqual(w[0], 0.0)
        self.assertAlmostEqual(w[200], 1.0)
        np.testing.assert_allclose(w[1:], w[1:][::-1], atol=1e-12)   # w[n] == w[400-n]

    def test_dct_is_orthonormal(self):
        d = kf.dct_matrix(N_MELS, N_MELS)
        np.testing.assert_allclose(d @ d.T, np.eye(N_MELS), atol=1e-12)

    def test_mel_filterbank(self):
        fb = kf.mel_filterbank()
        self.assertEqual(fb.shape, (kf.N_BINS, N_MELS))
        self.assertTrue(np.all(fb.max(axis=0) > 0), "every filter must catch at least one bin")
        self.assertTrue(np.all(fb <= 1.0 + 1e-12))
        # Neighbouring triangles add up to 1 between the first and the last centre.
        f_pts = kf.mel_to_hz(np.linspace(kf.hz_to_mel(0), kf.hz_to_mel(SAMPLE_RATE / 2), N_MELS + 2))
        freqs = np.linspace(0, SAMPLE_RATE // 2, kf.N_BINS)
        inside = (freqs >= f_pts[1]) & (freqs <= f_pts[N_MELS])
        np.testing.assert_allclose(fb[inside].sum(axis=1), 1.0, atol=1e-9)


class TestMfcc(unittest.TestCase):
    def test_sine_peaks_in_the_right_fft_bin(self):
        t = np.arange(CLIP_SAMPLES) / SAMPLE_RATE
        p = kf.power_spectrogram(0.5 * np.sin(2 * np.pi * 1000.0 * t))
        self.assertEqual(p.shape, (N_STFT_FRAMES, kf.N_BINS))
        self.assertEqual(int(np.argmax(p[50])), 25)                   # 25 bins * 40 Hz = 1 kHz

    def test_silence(self):
        c = kf.mfcc(np.zeros(CLIP_SAMPLES))
        self.assertEqual(c.shape, (N_STFT_FRAMES, N_MFCC))
        np.testing.assert_allclose(c[:, 0], -100.0 * np.sqrt(N_MELS), atol=1e-9)
        np.testing.assert_allclose(c[:, 1:], 0.0, atol=1e-9)

    def test_feature_vector_is_frame_major(self):
        rng = np.random.default_rng(0)
        pcm = rng.integers(-3000, 3000, CLIP_SAMPLES).astype(np.int16)
        feats = kf.clip_features(pcm)
        self.assertEqual(feats.shape, (N_IN,))
        self.assertEqual(feats.dtype, np.float32)
        pooled = kf.adaptive_avg_pool(kf.mfcc(pcm / 32768.0))
        self.assertEqual(pooled.shape, (N_FRAMES, N_MFCC))
        np.testing.assert_allclose(feats.reshape(N_FRAMES, N_MFCC), pooled, rtol=1e-5, atol=1e-4)

    def test_short_and_long_clips(self):
        rng = np.random.default_rng(1)
        pcm = rng.integers(-3000, 3000, CLIP_SAMPLES).astype(np.int16)
        short = kf.clip_features(pcm[:9000])
        padded = kf.clip_features(np.concatenate([pcm[:9000], np.zeros(CLIP_SAMPLES - 9000, np.int16)]))
        np.testing.assert_array_equal(short, padded)                  # zeros are added at the end
        np.testing.assert_array_equal(kf.clip_features(np.concatenate([pcm, pcm])), kf.clip_features(pcm))


class TestWav(unittest.TestCase):
    def _write(self, path, data, rate=SAMPLE_RATE):
        with wave.open(path, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(rate)
            w.writeframes(data.astype("<i2").tobytes())

    def test_round_trip_and_format_check(self):
        data = np.arange(-500, 500, dtype=np.int16)
        with tempfile.TemporaryDirectory() as d:
            ok, bad = os.path.join(d, "ok.wav"), os.path.join(d, "bad.wav")
            self._write(ok, data)
            np.testing.assert_array_equal(kf.read_wav(ok), data)
            self._write(bad, data, rate=8000)
            with self.assertRaises(ValueError):
                kf.read_wav(bad)


if __name__ == "__main__":
    unittest.main()
