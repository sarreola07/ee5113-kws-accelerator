#!/usr/bin/env python3
"""Live words and a UART self-test for the KWS accelerator on the Nexys board.

    python fpga/kws_live.py --selftest          # the 200 test clips, INT8 and INT4, through the UART:
                                                # does the board give Python's class and all 6 scores?
    python fpga/kws_live.py --mic               # say yes / no / on / off / left / right
    python fpga/kws_live.py --wav clip.wav      # a 16 kHz mono 16-bit .wav file
    python fpga/kws_live.py --mock --selftest   # no board: a software model answers (tests this script)

Options:
    --port COM5      the board's serial port (default: try every port, use the one that answers)
    --prec int4      precision (default int8; --selftest runs both unless --prec is given)
    --save DIR       keep every --mic recording as a .wav file in DIR

Install once:  pip install -r fpga/requirements-live.txt
The board must run a bitstream with the UART link, i.e. built from the 2026-11-20 sources
or later (fpga\\build.bat <board> program); the older prebuilt bitstream has no UART.
Live audio goes through the same MFCC, normalization and quantization as the training
data (python/live_frontend.py + weights/frontend.npz); for every live word the script also
runs the Python integer model on the same inputs and says whether the board agrees.
"""
import argparse
import sys
import time
import wave
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "python"))
import config as C          # noqa: E402
import live_frontend as F   # noqa: E402
import quant as Q           # noqa: E402

BAUD = 115200
PING = bytes([0xA5, 0x50, 0x50])
STATUS = {0: "ok", 1: "bad packet", 2: "pong"}


# ----------------------------------------------------------------- protocol ---
def encode_infer(bits, x):
    """'Run these inputs' packet: A5 49 prec x0..x249 chk (see fpga/kws_uart_link.v)."""
    prec = 0 if bits == 8 else 1
    data = bytes(int(v) & 0xFF for v in x)
    assert len(data) == C.N_INPUTS
    return bytes([0xA5, 0x49, prec]) + data + bytes([(0x49 + prec + sum(data)) & 0xFF])


def make_reply(status, cls=0, scores=(0,) * 6, cycles=0):
    body = bytes([status, cls]) + b"".join(int(s).to_bytes(4, "little", signed=True) for s in scores)
    body += int(cycles).to_bytes(2, "little")
    return bytes([0x5A]) + body + bytes([sum(body) & 0xFF])


def decode_reply(b):
    if len(b) != 30 or b[0] != 0x5A or (sum(b[1:29]) & 0xFF) != b[29]:
        raise ValueError(f"bad reply frame from the board: {b.hex()}")
    return {"status": b[1], "class": b[2],
            "scores": [int.from_bytes(b[3 + 4 * k:7 + 4 * k], "little", signed=True) for k in range(6)],
            "cycles": int.from_bytes(b[27:29], "little")}


# ------------------------------------------------------------------- boards ---
class Board:
    """The Nexys board on a serial port."""

    def __init__(self, port):
        import serial                                    # pyserial
        self.port = port
        self.ser = serial.Serial(port, BAUD, timeout=0.5)

    def transact(self, packet, timeout=3.0):
        self.ser.reset_input_buffer()
        self.ser.write(packet)
        end = time.time() + timeout
        while time.time() < end:
            c = self.ser.read(1)
            if c == b"\x5a":
                return decode_reply(c + self.ser.read(29))
        raise TimeoutError(f"no reply from {self.port}")

    def close(self):
        self.ser.close()


class MockBoard:
    """Software stand-in for the board: answers with the Python integer model."""
    port = "mock (no board)"

    def __init__(self):
        self.models = {b: Q.load_int_model(C.RESULTS_DIR / f"qmodel_int{b}.npz")[0] for b in C.BIT_WIDTHS}

    def transact(self, packet, timeout=None):
        if packet == PING:
            return decode_reply(make_reply(2))
        if (len(packet) != C.N_INPUTS + 4 or packet[:2] != b"\xa5\x49"
                or (sum(packet[1:-1]) & 0xFF) != packet[-1]):
            return decode_reply(make_reply(1))
        bits = 4 if packet[2] & 1 else 8
        x = np.array([v - 256 if v >= 128 else v for v in packet[3:-1]], dtype=np.int64)
        if bits == 4:
            x = np.where(x & 8, (x & 15) - 16, x & 15)    # the board uses only the low 4 bits
        pred, _, logits = Q.int_forward(self.models[bits], x[None, :])
        return decode_reply(make_reply(0, int(pred[0]), [int(v) for v in logits[0]], 0))

    def close(self):
        pass


def find_board(port=None):
    if port:
        ports = [port]
    else:
        from serial.tools import list_ports
        found = list_ports.comports()
        found.sort(key=lambda p: (getattr(p, "vid", None) != 0x0403, p.device))   # FTDI (Digilent) first
        ports = [p.device for p in found]
    for dev in ports:
        try:
            b = Board(dev)
        except Exception:
            continue
        try:
            if b.transact(PING, timeout=1.0)["status"] == 2:
                print(f"board found on {dev}")
                return b
        except Exception:
            pass
        b.close()
    sys.exit("No board answered. Check that the board is on, the micro-USB cable is in the PROG/UART\n"
             "port, a bitstream with the UART link is programmed (built from the 2026-11-20 sources or\n"
             "later: fpga\\build.bat <board> program), and no other program (serial terminal) has the\n"
             "port open. Ports tried: "
             + (", ".join(ports) or "none"))


# ------------------------------------------------------------------ helpers ---
def read_mem(path, bits=None):
    v = np.array([int(t, 16) for t in Path(path).read_text().split()], dtype=np.int64)
    if bits:
        v = np.where(v >= 1 << (bits - 1), v - (1 << bits), v)
    return v


def acc_w(bits):
    for line in (C.HW_DIR / f"int{bits}" / "kws_params.vh").read_text().splitlines():
        if "KWS_ACC_W" in line:
            return int(line.split()[2])
    raise ValueError("KWS_ACC_W not found")


def selftest(board, bit_list):
    """Send the 200 hardware test clips; the board must return Python's class and scores."""
    all_ok = True
    for bits in bit_list:
        d = C.HW_DIR / f"int{bits}"
        x = read_mem(d / "test_inputs.mem", bits).reshape(-1, C.N_INPUTS)
        want_c = read_mem(d / "test_expected.mem")
        want_s = read_mem(d / "test_logits.mem", acc_w(bits)).reshape(-1, len(C.WORDS))
        labels = read_mem(d / "test_labels.mem")
        bad, correct, t0 = [], 0, time.time()
        for c in range(len(x)):
            r = board.transact(encode_infer(bits, x[c]))
            if r["status"] != 0 or r["class"] != want_c[c] or r["scores"] != [int(v) for v in want_s[c]]:
                bad.append((c, r))
            correct += int(r["class"] == labels[c])
        n = len(x)
        print(f"INT{bits}: {n - len(bad)}/{n} clips identical to Python (class and all 6 scores), "
              f"{correct}/{n} words correct, {time.time() - t0:.1f} s")
        for c, r in bad[:10]:
            print(f"   clip {c:3d}: board {STATUS.get(r['status'], r['status'])} class {r['class']} "
                  f"scores {r['scores']}  |  Python class {want_c[c]} scores {list(want_s[c])}")
        if len(bad) > 10:
            print(f"   ... and {len(bad) - 10} more")
        all_ok &= not bad
    print("SELFTEST PASSED: the board matches Python bit for bit" if all_ok else "SELFTEST FAILED")
    return all_ok


def classify(board, audio, fe, bits, models):
    """Run 1 s of audio on the board and on the Python integer model."""
    x = F.to_inputs(audio, fe, bits)
    r = board.transact(encode_infer(bits, x))
    pred, _, logits = Q.int_forward(models[bits], x[None, :])
    same = r["status"] == 0 and r["class"] == pred[0] and r["scores"] == [int(v) for v in logits[0]]
    word = fe["words"][r["class"]] if r["status"] == 0 else "?"
    print(f"board: {word.upper():6s} scores {r['scores']}  ({r['cycles']} cycles)   "
          f"Python: {fe['words'][pred[0]]}   {'board == Python' if same else 'BOARD DIFFERS FROM PYTHON'}")
    return word, same


def read_wav(path):
    with wave.open(str(path), "rb") as w:
        if (w.getnchannels(), w.getsampwidth(), w.getframerate()) != (1, 2, C.SAMPLE_RATE):
            sys.exit(f"{path}: need a mono 16-bit {C.SAMPLE_RATE} Hz .wav file")
        return np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float32) / 32768.0


def write_wav(path, audio):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(C.SAMPLE_RATE)
        w.writeframes((np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes())


def mic_loop(board, fe, bits, models, save_dir):
    import sounddevice as sd
    print(f"Live words on INT{bits}. Say one of: {', '.join(fe['words'])}. Ctrl+C to stop.")
    n = 0
    while True:
        input("\nPress Enter, then say the word within 1.5 seconds ...")
        rec = sd.rec(int(1.5 * C.SAMPLE_RATE), samplerate=C.SAMPLE_RATE, channels=1, dtype="float32")
        sd.wait()
        audio = F.loudest_window(rec[:, 0])
        level = float(np.sqrt(np.mean(audio ** 2)))
        if level < 0.005:
            print(f"   very quiet (level {level:.4f}): check the microphone, speak closer")
        if save_dir:
            n += 1
            write_wav(Path(save_dir) / f"live_{time.strftime('%Y%m%d_%H%M%S')}_{n:03d}.wav", audio)
        classify(board, audio, fe, bits, models)


# --------------------------------------------------------------------- main ---
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--selftest", action="store_true", help="200 test clips through the UART")
    mode.add_argument("--mic", action="store_true", help="live words from the microphone")
    mode.add_argument("--wav", help="classify a 16 kHz mono .wav file")
    ap.add_argument("--port", help="serial port, e.g. COM5 or /dev/ttyUSB1")
    ap.add_argument("--prec", choices=["int8", "int4"], help="precision (default int8)")
    ap.add_argument("--mock", action="store_true", help="no board: a software model answers")
    ap.add_argument("--save", help="folder to keep --mic recordings in")
    a = ap.parse_args()

    board = MockBoard() if a.mock else find_board(a.port)
    try:
        if a.selftest:
            bit_list = [int(a.prec[3:])] if a.prec else C.BIT_WIDTHS
            sys.exit(0 if selftest(board, bit_list) else 1)
        bits = int(a.prec[3:]) if a.prec else 8
        fe = F.load()
        models = {b: Q.load_int_model(C.RESULTS_DIR / f"qmodel_int{b}.npz")[0] for b in C.BIT_WIDTHS}
        for b in C.BIT_WIDTHS:                   # frontend.npz must belong to the current model
            if fe["s_x"][b] != models[b]["s_x"]:
                sys.exit(f"weights/frontend.npz has s_x {fe['s_x'][b]} for INT{b}, but "
                         f"results/python/qmodel_int{b}.npz has {models[b]['s_x']}: the model was\n"
                         "retrained after the front end was exported. Run python python/export_frontend.py")
        if a.save:
            Path(a.save).mkdir(parents=True, exist_ok=True)
        if a.wav:
            classify(board, F.loudest_window(read_wav(a.wav)), fe, bits, models)
        else:
            mic_loop(board, fe, bits, models, a.save)
    except KeyboardInterrupt:
        print()
    finally:
        board.close()


if __name__ == "__main__":
    main()
