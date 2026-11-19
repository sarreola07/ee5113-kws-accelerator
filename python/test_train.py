"""Unit tests for the NumPy trainer (no dataset needed)."""
import unittest

import numpy as np

import train


class TestGradients(unittest.TestCase):
    def test_backprop_matches_finite_differences(self):
        rng = np.random.default_rng(0)
        p = train.init_params(rng, n_in=7, n_hid=5, n_out=3, dtype=np.float64)
        for k in p:                                    # non-zero biases, random weights
            p[k] = p[k] + rng.normal(0, 0.1, p[k].shape)
        x = rng.normal(0, 1, (11, 7))
        y = rng.integers(0, 3, 11)
        wd = 1e-3
        _, g = train.loss_and_grads(p, x, y, wd)
        eps = 1e-6
        for k in p:
            for _ in range(6):
                idx = tuple(rng.integers(0, s) for s in p[k].shape)
                old = p[k][idx]
                p[k][idx] = old + eps
                lp, _ = train.loss_and_grads(p, x, y, wd)
                p[k][idx] = old - eps
                lm, _ = train.loss_and_grads(p, x, y, wd)
                p[k][idx] = old
                num = (lp - lm) / (2 * eps)
                rel = abs(num - g[k][idx]) / max(1e-8, abs(num) + abs(g[k][idx]))
                self.assertLess(rel, 1e-6, f"{k}{idx}: numeric {num} vs backprop {g[k][idx]}")


class TestTraining(unittest.TestCase):
    def test_learns_separable_blobs(self):
        rng = np.random.default_rng(1)
        centres = rng.normal(0, 1, (6, 250))

        def blobs(n):
            y = rng.integers(0, 6, n)
            return (centres[y] + rng.normal(0, 1.0, (n, 250))).astype(np.float32), y

        x_tr, y_tr = blobs(1200)
        x_val, y_val = blobs(300)
        p, hist = train.train(x_tr, y_tr, x_val, y_val, epochs=15, verbose=False)
        acc, _ = train.evaluate(p, x_val, y_val)
        self.assertGreater(acc, 0.95)
        self.assertEqual(p["w1"].shape, (32, 250))
        self.assertEqual(p["w2"].shape, (6, 32))
        self.assertGreaterEqual(hist["best_epoch"], 1)


if __name__ == "__main__":
    unittest.main()
