"""Say a keyword into the PC microphone: the FPGA recognizes it and shows it on the 7-segment display.

    python fpga/mic_demo.py                 # listen on the default microphone (Ctrl+C to stop)
    python fpga/mic_demo.py --clips         # no microphone: send the 200 test clips, check every answer
    python fpga/mic_demo.py --wav a.wav     # classify wav files (any rate, 16-bit PCM)
    python fpga/mic_demo.py --list          # list the microphones; pick one with --device N

Words: yes, no, on, off, left, right. No switches are needed on the board.

The board must run results/fpga/kws_fpga_top_<board>.bit (fpga\\program.bat <board>).
The PC does what this project always did in software (python/): MFCC (mfcc.py), normalization,
and quantization to INT8 and INT4 (quant.py). It sends both input vectors over the board's
USB-UART (115200 baud). The FPGA runs both accelerators on them, shows the word and answers
with one text line. The PC also runs the Python integer model on the same inputs, so every
word is also a bit-exact check of the hardware ("same as Python").

Needs: numpy, pyserial, sounddevice   (python -m pip install numpy pyserial sounddevice)
"""
import argparse
import queue
import re
import sys
import time
import wave
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "python"))
import config as C          # noqa: E402
import quant as Q           # noqa: E402
from mfcc import mfcc       # noqa: E402

SR = C.SAMPLE_RATE                       # 16 kHz, 1 s per word
MIC_RE = re.compile(r"MIC (\d+): INT8 heard (\S+)\s*\(Python (\S+)\s*\) \| "
                    r"INT4 heard (\S+)\s*\(Python (\S+)\s*\) -> (.*)")


# ---------------------------------------------------------------- models and front end
class FrontEnd:
    """Audio (16 kHz, 1 s) -> INT8 and INT4 inputs, plus the Python integer model's answers."""

    def __init__(self, agc=True):
        self.m8, self.words = Q.load_int_model(C.RESULTS_DIR / "qmodel_int8.npz")
        self.m4, _ = Q.load_int_model(C.RESULTS_DIR / "qmodel_int4.npz")
        norm = np.load(C.RESULTS_DIR / "feature_norm.npz")
        self.mean, self.std = norm["mean"], norm["std"]
        self.c0_target = float(norm["c0_max_median"])
        self.agc = agc

    def inputs(self, clip):
        """Returns x8, x4, gain. With agc the clip is scaled to the typical training loudness."""
        clip = np.asarray(clip, np.float64)
        gain = 1.0
        if self.agc:
            # a gain g adds 2*ln(g)*sqrt(N_MELS) to the first MFCC coefficient (c0)
            c0_max = mfcc(clip)[0].reshape(C.N_FRAMES, C.N_MFCC)[:, 0].max()
            gain = float(np.clip(np.exp((self.c0_target - c0_max) / (2 * np.sqrt(C.N_MELS))), 0.1, 30.0))
        z = (mfcc(clip * gain)[0] - self.mean) / self.std
        return Q.quantize(z, self.m8["s_x"], 8), Q.quantize(z, self.m4["s_x"], 4), gain

    def python_answer(self, x8, x4):
        p8 = int(Q.int_forward(self.m8, np.asarray(x8)[None])[0][0])
        p4 = int(Q.int_forward(self.m4, np.asarray(x4)[None])[0][0])
        return p8, p4


# ---------------------------------------------------------------- board link
def find_port():
    from serial.tools import list_ports
    ports = [p.device for p in list_ports.comports() if p.vid == 0x0403 and p.pid == 0x6010]
    return sorted(ports)[-1] if ports else None


class Board:
    """The board's USB-UART: send one word, read the text lines the FPGA sends back."""

    def __init__(self, port, echo=True):
        import serial
        self.ser = serial.Serial(port, 115200, timeout=0)
        self.buf = b""
        self.echo = echo                     # print lines that are not answers (switch use, self-test)
        time.sleep(0.1)
        self.ser.reset_input_buffer()

    def read_lines(self):
        self.buf += self.ser.read(4096)
        *lines, self.buf = self.buf.split(b"\n")
        return [l.decode("ascii", "replace").strip() for l in lines if l.strip()]

    def poll(self):
        """Print whatever the board said on its own (e.g. a self-test after CPU_RESET)."""
        for line in self.read_lines():
            if self.echo:
                print(f"\r  board: {line}" + " " * 10)

    def send(self, x8, x4, e8, e4):
        # "K", Python INT8 class, Python INT4 class, 250 INT8 inputs, 250 INT4 inputs, checksum
        body = (bytes([e8 & 7, e4 & 7]) + (np.asarray(x8) & 0xFF).astype(np.uint8).tobytes()
                + (np.asarray(x4) & 0x0F).astype(np.uint8).tobytes())
        self.ser.write(b"K" + body + bytes([sum(body) & 0xFF]))

    def answer(self, timeout=2.0):
        """Waits for the FPGA's "MIC ..." line. Returns the regex match, or None."""
        end = time.time() + timeout
        while time.time() < end:
            for line in self.read_lines():
                m = MIC_RE.match(line)
                if m:
                    return m
                if self.echo:
                    print(f"  board: {line}")
            time.sleep(0.005)
        return None

    def classify(self, x8, x4, e8, e4):
        for attempt in range(2):
            self.send(x8, x4, e8, e4)
            m = self.answer()
            if m:
                return m
            time.sleep(0.1)                  # > 50 ms: the FPGA drops a half packet, then retry
        return None


NO_ANSWER = ("no answer from the FPGA. Is the board on and loaded with a bitstream that has the "
             "microphone input (fpga\\program.bat nexys4ddr)?")


# ---------------------------------------------------------------- audio helpers
def resample(x, n):
    """FFT resampling of a short clip to n samples."""
    X = np.fft.rfft(x)
    Y = np.zeros(n // 2 + 1, complex)
    k = min(len(X), len(Y))
    Y[:k] = X[:k]
    return np.fft.irfft(Y, n) * (n / len(x))


def loudest_second(x):
    """The 1 s window (16000 samples) with the most energy, so the word is in the middle."""
    if len(x) <= SR:
        return np.pad(x, (0, SR - len(x)))
    e = np.concatenate([[0.0], np.cumsum(x.astype(np.float64) ** 2)])
    starts = np.arange(0, len(x) - SR + 1, 160)
    s = starts[np.argmax(e[starts + SR] - e[starts])]
    return x[s:s + SR]


def read_any_wav(path):
    with wave.open(str(path), "rb") as w:
        if w.getsampwidth() != 2:
            raise ValueError(f"{path}: only 16-bit PCM wav files")
        x = np.frombuffer(w.readframes(w.getnframes()), "<i2").astype(np.float64) / 32768.0
        x = x.reshape(-1, w.getnchannels()).mean(axis=1)
        rate = w.getframerate()
    if rate != SR:
        x = resample(x, int(round(len(x) * SR / rate)))
    return loudest_second(x)


def write_wav(path, x):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes((np.clip(x, -1, 1) * 32767).astype("<i2").tobytes())


def db(v):
    return 20 * np.log10(max(v, 1e-9))


# ---------------------------------------------------------------- one word
def run_word(fe, board, clip, n, info=""):
    x8, x4, gain = fe.inputs(clip)
    p8, p4 = fe.python_answer(x8, x4)
    m = board.classify(x8, x4, p8, p4)
    if not m:
        print(f"\r  {n:3d}: {NO_ANSWER}")
        return None
    f8, f4 = m.group(2), m.group(4)
    same = m.group(6).startswith("same")
    print(f"\r  {n:3d}: FPGA heard {f8.upper():6s} (INT8 {f8:5s} INT4 {f4:5s} | Python INT8 "
          f"{fe.words[p8]:5s} INT4 {fe.words[p4]:5s} -> {'same as Python' if same else 'DIFFERENT'})"
          f"  {info}gain x{gain:.1f}" + " " * 6)
    return f8, f4, same


# ---------------------------------------------------------------- modes
def mode_clips(fe, board):
    """Sends the 200 test clips the FPGA also has in ROM; the answers must equal Python."""
    def mem(name, bits=None):                      # hex file; bits = signed width
        v = np.array([int(t, 16) for t in (ROOT / "fpga" / "mem" / name).read_text().split()])
        return v if bits is None else np.where(v >= 2 ** (bits - 1), v - 2 ** bits, v)
    x8 = mem("int8_inputs256.mem", 8).reshape(200, 256)[:, :250]
    x4 = mem("int4_inputs256.mem", 4).reshape(200, 256)[:, :250]
    e8, e4, lab = mem("int8_expected.mem"), mem("int4_expected.mem"), mem("int8_labels.mem")
    board.echo = False
    tally = {"c8": 0, "c4": 0, "m8": 0, "m4": 0}
    t0 = time.time()
    for c in range(200):
        p8, p4 = fe.python_answer(x8[c], x4[c])
        if (p8, p4) != (e8[c], e4[c]):
            print(f"  warning: clip {c}: results/python model differs from fpga/mem (re-run gen_fpga_mem.py?)")
        m = board.classify(x8[c], x4[c], int(e8[c]), int(e4[c]))
        if not m:
            print(f"  clip {c}: {NO_ANSWER}")
            return 1
        f8, f4 = fe.words.index(m.group(2)), fe.words.index(m.group(4))
        tally["c8"] += f8 == lab[c]; tally["c4"] += f4 == lab[c]
        tally["m8"] += f8 == e8[c];  tally["m4"] += f4 == e4[c]
        print(f"\r  clip {c:3d}/200  INT8 {m.group(2):5s} INT4 {m.group(4):5s} (true word {fe.words[lab[c]]})",
              end="", flush=True)
    ok = tally["m8"] == 200 and tally["m4"] == 200
    print(f"\r  200 clips sent over the UART in {time.time() - t0:.0f} s" + " " * 40)
    print(f"  INT8 {tally['c8']}/200 correct, {tally['m8']}/200 same as Python; "
          f"INT4 {tally['c4']}/200 correct, {tally['m4']}/200 same as Python -> {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


def mode_wav(fe, board, paths):
    for i, p in enumerate(paths, 1):
        print(f"  {p}")
        run_word(fe, board, read_any_wav(p), i)
    return 0


def mode_mic(fe, board, args):
    import sounddevice as sd
    dev = args.device
    info = sd.query_devices(dev, "input")
    rate = SR
    try:
        sd.check_input_settings(device=dev, samplerate=SR, channels=1)
    except Exception:
        rate = int(info["default_samplerate"])     # record at the device rate, resample each word
    block = rate // 50                             # 20 ms
    q = queue.Queue()
    stream = sd.InputStream(device=dev, channels=1, samplerate=rate, blocksize=block, dtype="float32",
                            callback=lambda data, frames, t, status: q.put(data[:, 0].copy()))
    pre, post = int(0.3 * 50), int(0.9 * 50)       # blocks kept before / recorded after the start
    hist = []                                      # last blocks (enough for pre + post)
    save = Path(args.save) if args.save else None
    if save:
        save.mkdir(parents=True, exist_ok=True)

    print(f"Microphone: {info['name']} ({rate} Hz)")
    print("Calibrating: stay quiet for 1 second ...")
    with stream:
        quiet = [float(np.sqrt(np.mean(q.get() ** 2))) for _ in range(50)]
        noise = float(np.median(quiet))
        print(f"Noise level {db(noise):.0f} dB. Say one word at a time: {', '.join(fe.words)}  (Ctrl+C to stop)")
        n, left, cool, k = 0, -1, 0, 0
        while True:
            b = q.get()
            hist.append(b)
            del hist[:-(pre + post + 5)]
            rms = float(np.sqrt(np.mean(b ** 2)))
            thr = max(noise * args.threshold, args.min_level)
            k += 1
            if left < 0:                                       # waiting for a word
                if cool > 0:
                    cool -= 1
                elif rms > thr:
                    left = post
                else:
                    noise = 0.98 * noise + 0.02 * rms          # follow slow changes of the room
                if k % 5 == 0:
                    bar = int(np.clip((db(rms) + 60) / 2, 0, 30))
                    mark = int(np.clip((db(thr) + 60) / 2, 0, 30))
                    s = "".join("#" if i < bar else ("|" if i == mark else ".") for i in range(31))
                    sys.stdout.write(f"\r  level [{s}] {db(rms):4.0f} dB ")
                    sys.stdout.flush()
                    board.poll()
            else:                                              # recording the rest of the word
                left -= 1
                if left == 0:
                    left, cool = -1, 10                        # 0.2 s before the next word
                    audio = np.concatenate(hist[-(pre + post):])
                    if rate != SR:
                        audio = resample(audio, int(round(len(audio) * SR / rate)))
                    clip = loudest_second(audio)
                    n += 1
                    if save:
                        write_wav(save / f"word_{n:03d}.wav", clip)
                    peak = max(np.sqrt(np.mean(f ** 2)) for f in clip.reshape(-1, 400))
                    run_word(fe, board, clip, n, info=f"level {db(peak):.0f} dB, ")
                    while not q.empty():                       # skip audio recorded while busy
                        hist.append(q.get())
                    del hist[:-(pre + post + 5)]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--port", help="board COM port (default: the Digilent USB-UART)")
    ap.add_argument("--clips", action="store_true", help="send the 200 test clips instead of the microphone")
    ap.add_argument("--wav", nargs="+", help="classify these wav files")
    ap.add_argument("--list", action="store_true", help="list the microphones")
    ap.add_argument("--device", type=int, default=None, help="microphone number from --list")
    ap.add_argument("--threshold", type=float, default=3.0, help="word starts at this many times the noise level")
    ap.add_argument("--min-level", type=float, default=0.01, help="... and at least this RMS level (0..1)")
    ap.add_argument("--no-agc", action="store_true", help="do not scale the word to the training loudness")
    ap.add_argument("--save", help="also save each word as a wav file in this folder")
    args = ap.parse_args()

    if args.list:
        import sounddevice as sd
        print(sd.query_devices())
        return 0
    port = args.port or find_port()
    if not port:
        print("No Digilent board COM port found. Is the board on and plugged in (USB-PROG/UART port)?")
        return 1
    try:
        board = Board(port)
    except Exception as e:
        print(f"Cannot open {port}: {e}\n(close PuTTY / Tera Term / monitor.ps1 if one has the port open)")
        return 1
    print(f"Board on {port}")
    fe = FrontEnd(agc=not args.no_agc)
    try:
        if args.clips:
            return mode_clips(fe, board)
        if args.wav:
            return mode_wav(fe, board, args.wav)
        return mode_mic(fe, board, args)
    except KeyboardInterrupt:
        print("\nStopped.")
        return 0


if __name__ == "__main__":
    sys.exit(main())
