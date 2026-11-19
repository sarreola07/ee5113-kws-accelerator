#!/usr/bin/env python3
"""Download Google Speech Commands v0.02, keeping only the project's 6 words.

    python python/kws_data.py                  # stream from the internet (~2.4 GB read)
    python python/kws_data.py --tar FILE.tar.gz  # use an archive you already downloaded

The archive is streamed and unpacked on the fly, so the 2.4 GB file is never
stored. Only the 6 word folders plus testing_list.txt / validation_list.txt
(the official splits), LICENSE and README.md are kept: about 0.75 GB in
python/data/speech_commands_v0.02/ (git-ignored). The MD5 of the whole stream
is checked against the official archive. Files that are already there are
skipped, so an interrupted download can simply be run again.

Dataset: "Speech Commands: A Dataset for Limited-Vocabulary Speech Recognition",
P. Warden, 2018 (arXiv:1804.03209). License: CC BY 4.0.
"""
import argparse
import hashlib
import http.client
import json
import os
import re
import sys
import tarfile
import time
import urllib.request
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kws_common import WORDS  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_DEST = os.path.join(ROOT, "python", "data", "speech_commands_v0.02")
URL = "https://storage.googleapis.com/download.tensorflow.org/data/speech_commands_v0.02.tar.gz"
MD5 = "6b74f3901214cb2c2934e98196829835"
SIZE = 2428923189
EXTRA_FILES = ("testing_list.txt", "validation_list.txt", "LICENSE", "README.md")
MARKER = ".complete"

# Paths are built from these matches, never from the archive's own names.
_WAV_RE = re.compile(r"^(?:\./)?(" + "|".join(map(re.escape, WORDS)) + r")/([0-9a-f]{8}_nohash_\d+\.wav)$")
_EXTRA_RE = re.compile(r"^(?:\./)?(" + "|".join(map(re.escape, EXTRA_FILES)) + r")$")
_RETRY_ERRORS = (OSError, EOFError, tarfile.TarError, http.client.HTTPException, zlib.error)


class _CountingReader:
    """File wrapper that hashes and counts every byte read, and prints progress."""

    def __init__(self, raw, total):
        self.raw, self.total = raw, total
        self.md5, self.n, self._next, self.t0 = hashlib.md5(), 0, 0, time.time()

    def read(self, size=-1):
        b = self.raw.read(size) if size is not None and size >= 0 else self.raw.read()
        self.md5.update(b)
        self.n += len(b)
        if self.n >= self._next or not b:
            self._next += 200 << 20
            rate = self.n / 1e6 / max(time.time() - self.t0, 1e-6)
            pct = f" ({100 * self.n / self.total:4.1f}%)" if self.total else ""
            print(f"  read {self.n / 1e6:7.0f} MB{pct}  {rate:5.1f} MB/s", flush=True)
        return b


def _write_member(tar, member, out):
    if os.path.exists(out) and os.path.getsize(out) == member.size:
        return                                   # already extracted (resumed run)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    data = tar.extractfile(member).read()
    if len(data) != member.size:
        raise EOFError(f"short read for {member.name}")
    if out.endswith(".wav") and (data[:4] != b"RIFF" or data[8:12] != b"WAVE"):
        raise ValueError(f"{member.name} is not a WAV file")
    tmp = out + ".part"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, out)


def _stream_extract(dest, url, tar_path, limit_per_word):
    raw = open(tar_path, "rb") if tar_path else urllib.request.urlopen(url, timeout=60)
    total = os.path.getsize(tar_path) if tar_path else int(raw.headers.get("Content-Length") or 0) or None
    reader = _CountingReader(raw, total)
    counts = {w: 0 for w in WORDS}
    extras = set()
    stopped_early = False
    with raw:
        with tarfile.open(fileobj=reader, mode="r|gz") as tar:
            for m in tar:
                if not m.isfile():
                    continue
                mw = _WAV_RE.match(m.name)
                if mw:
                    word, fname = mw.groups()
                    if limit_per_word and counts[word] >= limit_per_word:
                        continue
                    _write_member(tar, m, os.path.join(dest, word, fname))
                    counts[word] += 1
                    if limit_per_word and all(c >= limit_per_word for c in counts.values()):
                        stopped_early = True
                        break
                    continue
                me = _EXTRA_RE.match(m.name)
                if me:
                    _write_member(tar, m, os.path.join(dest, me.group(1)))
                    extras.add(me.group(1))
        if not stopped_early:
            while reader.read(1 << 20):          # read to the end so the MD5 covers the whole file
                pass
    return counts, extras, reader, stopped_early


def download(dest=DEFAULT_DEST, url=URL, tar_path=None, retries=3, limit_per_word=0, verify=True):
    """Fetch and unpack the 6 words. limit_per_word > 0 stops early (quick tests only)."""
    if not limit_per_word and is_complete(dest):
        print(f"dataset already complete in {dest}")
        return json.load(open(os.path.join(dest, MARKER)))
    os.makedirs(dest, exist_ok=True)
    print(f"streaming {tar_path or url}\n  keeping {', '.join(WORDS)} -> {dest}")
    attempt = 0
    while True:
        attempt += 1
        try:
            counts, extras, reader, stopped_early = _stream_extract(dest, url, tar_path, limit_per_word)
            break
        except _RETRY_ERRORS as e:
            if tar_path or attempt > retries:
                raise
            wait = 10 * attempt
            print(f"download interrupted ({e!r}); retrying in {wait} s (attempt {attempt + 1})", flush=True)
            time.sleep(wait)
    info = {"counts": counts, "bytes": reader.n, "md5": reader.md5.hexdigest(),
            "source": tar_path or url, "words": WORDS}
    if stopped_early:
        info["partial"] = True
        return info
    if verify and (info["md5"] != MD5 or info["bytes"] != SIZE):
        raise RuntimeError(f"archive check failed: md5 {info['md5']} ({info['bytes']} bytes), expected "
                           f"{MD5} ({SIZE} bytes). Delete {dest} and download again.")
    missing = [f for f in ("testing_list.txt", "validation_list.txt") if f not in extras
               and not os.path.exists(os.path.join(dest, f))]
    if missing or not all(counts.values()):
        raise RuntimeError(f"archive is missing {missing or 'some word folders'}")
    with open(os.path.join(dest, MARKER), "w") as f:
        json.dump(info, f, indent=2)
    print("done: " + ", ".join(f"{w} {c}" for w, c in counts.items()))
    return info


def is_complete(dest=DEFAULT_DEST):
    try:
        info = json.load(open(os.path.join(dest, MARKER)))
    except (OSError, ValueError):
        return False
    return info.get("md5") == MD5 and all(info.get("counts", {}).get(w) for w in WORDS)


def split_files(dest=DEFAULT_DEST):
    """{'train'|'val'|'test': [(path, label), ...]} using the official split lists."""
    def read_list(name):
        with open(os.path.join(dest, name)) as f:
            return {line.strip() for line in f if line.strip()}
    test, val = read_list("testing_list.txt"), read_list("validation_list.txt")
    splits = {"train": [], "val": [], "test": []}
    for label, word in enumerate(WORDS):
        folder = os.path.join(dest, word)
        for fname in sorted(os.listdir(folder)):
            if not fname.endswith(".wav"):
                continue
            rel = f"{word}/{fname}"
            split = "test" if rel in test else "val" if rel in val else "train"
            splits[split].append((os.path.join(folder, fname), label))
    return splits


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dest", default=DEFAULT_DEST)
    ap.add_argument("--tar", help="local copy of speech_commands_v0.02.tar.gz")
    ap.add_argument("--no-verify", action="store_true", help="skip the MD5 check (custom archives)")
    args = ap.parse_args()
    download(args.dest, tar_path=args.tar, verify=not args.no_verify)
    s = split_files(args.dest)
    print("splits: " + ", ".join(f"{k} {len(v)}" for k, v in s.items()))


if __name__ == "__main__":
    main()
