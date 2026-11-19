"""Step 1: download Google Speech Commands (only the chosen words) and compute MFCC features.

    python python/prepare_data.py               # real dataset (streams a ~2.3 GB archive once)
    python python/prepare_data.py --synthetic   # fake tone data, only to test the pipeline quickly

Output: data/features.npz with normalized train / validation / test features and labels.
The official validation_list.txt / testing_list.txt splits are used, so no speaker
appears in more than one split.
"""
import argparse
import sys
import tarfile
import urllib.request
import wave

import numpy as np

import config as C
from mfcc import mfcc

LIST_FILES = ("validation_list.txt", "testing_list.txt", "LICENSE")


# ---------------------------------------------------------------- download
class _ProgressReader:
    """Wraps the HTTP response so we can print download progress."""

    def __init__(self, f, total):
        self.f, self.total, self.done, self.next_report = f, total, 0, 0

    def read(self, n=-1):
        data = self.f.read(n)
        self.done += len(data)
        if self.done >= self.next_report:
            pct = f" ({100 * self.done / self.total:.0f}%)" if self.total else ""
            print(f"  downloaded {self.done / 1e6:7.0f} MB{pct}", flush=True)
            self.next_report += 100_000_000
        return data


def download(words):
    marker = C.SPEECH_DIR / ".complete"
    if marker.exists() and set(marker.read_text().split()) >= set(words):
        print(f"Dataset already in {C.SPEECH_DIR}")
        return
    wanted = set(words)
    C.SPEECH_DIR.mkdir(parents=True, exist_ok=True)
    print(f"Downloading {C.DATASET_URL}")
    print(f"Keeping only: {', '.join(words)} (the archive is streamed, not saved)")
    request = urllib.request.Request(C.DATASET_URL, headers={"User-Agent": "python-urllib"})
    kept = 0
    with urllib.request.urlopen(request) as response:
        total = int(response.headers.get("Content-Length") or 0)
        with tarfile.open(fileobj=_ProgressReader(response, total), mode="r|gz") as tar:
            for member in tar:
                name = member.name[2:] if member.name.startswith("./") else member.name
                parts = name.split("/")
                if not member.isfile() or any(p in ("", "..") for p in parts):
                    continue
                is_word_wav = len(parts) == 2 and parts[0] in wanted and parts[1].endswith(".wav")
                if not (is_word_wav or name in LIST_FILES):
                    continue
                dest = C.SPEECH_DIR.joinpath(*parts)
                dest.parent.mkdir(parents=True, exist_ok=True)
                with tar.extractfile(member) as src:
                    dest.write_bytes(src.read())
                kept += is_word_wav
    marker.write_text("\n".join(sorted(wanted)))
    print(f"Saved {kept} clips to {C.SPEECH_DIR}")


# ---------------------------------------------------------------- audio -> features
def read_wav(path):
    """16-bit mono 16 kHz wav -> float32 array of exactly CLIP_SAMPLES (zero padded)."""
    with wave.open(str(path), "rb") as w:
        if (w.getsampwidth(), w.getnchannels(), w.getframerate()) != (2, 1, C.SAMPLE_RATE):
            raise ValueError(f"{path}: expected 16-bit mono {C.SAMPLE_RATE} Hz")
        x = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float32) / 32768.0
    out = np.zeros(C.CLIP_SAMPLES, np.float32)
    n = min(len(x), C.CLIP_SAMPLES)
    out[:n] = x[:n]
    return out


def split_files(words):
    def read_list(name):
        return set((C.SPEECH_DIR / name).read_text().split())

    val, test = read_list("validation_list.txt"), read_list("testing_list.txt")
    splits = {"train": [], "val": [], "test": []}
    for label, word in enumerate(words):
        for path in sorted((C.SPEECH_DIR / word).glob("*.wav")):
            rel = f"{word}/{path.name}"
            split = "val" if rel in val else "test" if rel in test else "train"
            splits[split].append((path, label))
    return splits


def features_for(items, name, chunk=500):
    X = np.empty((len(items), C.N_INPUTS), np.float32)
    y = np.array([label for _, label in items], np.int64)
    for i in range(0, len(items), chunk):
        audio = np.stack([read_wav(p) for p, _ in items[i:i + chunk]])
        X[i:i + len(audio)] = mfcc(audio)
        print(f"  {name}: {min(i + chunk, len(items))}/{len(items)} clips", end="\r", flush=True)
    print()
    return X, y


def synthetic_split(words, n_per_class=300):
    """Each class is a noisy tone at a different pitch. Only for testing the code path."""
    rng = np.random.default_rng(C.SEED)
    t = np.arange(C.CLIP_SAMPLES) / C.SAMPLE_RATE
    audio, labels = [], []
    for label in range(len(words)):
        for _ in range(n_per_class):
            f0 = 300.0 * (label + 1) * (1 + 0.05 * rng.standard_normal())
            clip = 0.3 * np.sin(2 * np.pi * f0 * t + rng.uniform(0, 2 * np.pi))
            audio.append(clip + 0.05 * rng.standard_normal(C.CLIP_SAMPLES))
            labels.append(label)
    X, y = mfcc(np.array(audio)), np.array(labels, np.int64)
    order = rng.permutation(len(y))
    X, y = X[order], y[order]
    a, b = int(0.7 * len(y)), int(0.85 * len(y))
    return (X[:a], y[:a]), (X[a:b], y[a:b]), (X[b:], y[b:])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--synthetic", action="store_true", help="use fake tone data (pipeline test)")
    ap.add_argument("--out", default=None, help="output .npz (default data/features.npz)")
    args = ap.parse_args()

    words = C.WORDS
    if args.synthetic:
        out = args.out or C.DATA_DIR / "features_synthetic.npz"
        (Xtr, ytr), (Xva, yva), (Xte, yte) = synthetic_split(words)
    else:
        out = args.out or C.FEATURES_FILE
        download(words)
        splits = split_files(words)
        print("Computing MFCC features...")
        Xtr, ytr = features_for(splits["train"], "train")
        Xva, yva = features_for(splits["val"], "val")
        Xte, yte = features_for(splits["test"], "test")

    # Normalize every feature with the training-set mean / std (applied in software
    # before the features are quantized and sent to the accelerator).
    mean, std = Xtr.mean(axis=0), Xtr.std(axis=0) + 1e-6
    norm = lambda X: ((X - mean) / std).astype(np.float32)

    C.DATA_DIR.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(out, X_train=norm(Xtr), y_train=ytr, X_val=norm(Xva), y_val=yva,
                        X_test=norm(Xte), y_test=yte, mean=mean, std=std, words=np.array(words))
    print(f"Saved {out}")
    for name, y in (("train", ytr), ("val", yva), ("test", yte)):
        counts = ", ".join(f"{w}={c}" for w, c in zip(words, np.bincount(y, minlength=len(words))))
        print(f"  {name:5s} {len(y):6d} clips  ({counts})")


if __name__ == "__main__":
    sys.exit(main())
