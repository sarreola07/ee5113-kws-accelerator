"""Step 4 (optional): make PNG images for the PowerPoint slides.

    python python/make_figures.py

Reads data/features.npz, results/ and results/logs/, writes figures/:
  01_pipeline.png             block diagram: software front end + hardware accelerator
  02_mfcc_examples.png        what the network sees: one MFCC "image" per word
  03_training_curves.png      FP32 training and INT8/INT4 quantization-aware fine-tuning
  04_accuracy_all_models.png  test accuracy: FP32, INT8 PTQ/QAT, INT4 PTQ/QAT
  05_accuracy_vs_memory.png   key result: accuracy and weight memory per precision
  06_weight_histograms.png    layer-1 weights in FP32, INT8 (255 levels), INT4 (15 levels)
  07_confusion_int8.png / 07_confusion_int4.png
  screen_*.png                terminal-style images of each step's real console output
"""
import argparse
import csv
import re
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
from matplotlib.colors import LinearSegmentedColormap  # noqa: E402
from matplotlib.patches import FancyBboxPatch, Polygon, Rectangle  # noqa: E402

import config as C  # noqa: E402
import quant as Q  # noqa: E402

FIG_DIR = C.RESULTS_DIR / "figures"
LOG_DIR = C.RESULTS_DIR / "logs"
DPI = 200

# ---------------------------------------------------------------- palette (light mode)
SURFACE, PRIMARY, SECONDARY, MUTED = "#fcfcfb", "#0b0b0b", "#52514e", "#898781"
GRID, BASELINE = "#e1e0d9", "#c3c2b7"
# Color follows the precision in every figure: FP32 blue, INT8 orange, INT4 aqua
PREC_COLOR = {"FP32": "#2a78d6", "INT8": "#eb6834", "INT4": "#1baf7a"}
BLUE_RAMP = ["#cde2fb", "#9ec5f4", "#6da7ec", "#3987e5", "#256abf", "#184f95", "#0d366b"]
SEQ = LinearSegmentedColormap.from_list("seq_blue", BLUE_RAMP)
DIV = LinearSegmentedColormap.from_list(
    "div", ["#184f95", "#6da7ec", "#f0efec", "#ef8a89", "#a82f2e"])

plt.rcParams.update({
    "font.family": ["Segoe UI", "DejaVu Sans"], "font.size": 11,
    "figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE,
    "text.color": PRIMARY, "axes.labelcolor": SECONDARY, "axes.edgecolor": BASELINE,
    "xtick.color": MUTED, "ytick.color": MUTED, "xtick.labelcolor": SECONDARY,
    "ytick.labelcolor": SECONDARY, "axes.titlecolor": PRIMARY, "axes.titlesize": 13,
    "axes.titleweight": "bold", "axes.titlelocation": "left", "axes.titlepad": 10,
    "axes.spines.top": False, "axes.spines.right": False, "xtick.major.size": 0,
    "ytick.major.size": 0, "axes.linewidth": 0.8, "legend.frameon": False,
})


def precision_of(name):
    return name.split("-")[0]


def recessive_grid(ax, axis="y"):
    ax.grid(axis=axis, color=GRID, linewidth=0.8, linestyle="-")
    ax.set_axisbelow(True)
    if axis == "x":
        ax.spines["left"].set_color(BASELINE)
        ax.spines["bottom"].set_visible(False)
    else:
        ax.spines["left"].set_visible(False)


def percent_axis(ax, axis="y"):
    fmt = matplotlib.ticker.FuncFormatter(lambda v, _: f"{v:g}%")
    (ax.yaxis if axis == "y" else ax.xaxis).set_major_formatter(fmt)


def draw_bars(ax, positions, values, colors, horizontal):
    """Thin bars with a 4px rounded data end and a square baseline. Limits must be set first."""
    fig = ax.figure
    fig.canvas.draw()
    p0, p1 = ax.transData.transform((0, 0)), ax.transData.transform((1, 1))
    px_x, px_y = abs(p1[0] - p0[0]), abs(p1[1] - p0[1])
    r_px, thick_px = 0.045 * fig.dpi, 0.24 * fig.dpi
    arc = np.linspace(0, np.pi / 2, 8)
    for pos, val, color in zip(positions, values, colors):
        # Outline in (length, across) units: square at 0, two rounded corners at the data end
        r_len = min(r_px / (px_x if horizontal else px_y), val / 2)
        half = thick_px / (px_y if horizontal else px_x) / 2
        r_acr = min(r_px / (px_y if horizontal else px_x), half)
        top = [(val - r_len + r_len * np.sin(a), half - r_acr + r_acr * np.cos(a)) for a in arc]
        bot = [(val - r_len + r_len * np.cos(a), -half + r_acr - r_acr * np.sin(a)) for a in arc]
        outline = [(0, -half), (0, half)] + top + bot
        pts = [(L, pos + A) if horizontal else (pos + A, L) for L, A in outline]
        ax.add_patch(Polygon(pts, closed=True, fc=color, ec="none", zorder=3))


def save(fig, name):
    path = FIG_DIR / name
    fig.savefig(path, dpi=DPI)
    plt.close(fig)
    print(f"  {path.relative_to(C.ROOT)}")


# ---------------------------------------------------------------- figures
def fig_pipeline(words):
    fig = plt.figure(figsize=(12.6, 3.4))
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(0, 12.6)
    ax.set_ylim(0, 3.4)
    ax.axis("off")
    w, h, y = 1.35, 0.95, 1.25
    groups = [(0.15, 5.0, "Software  (Python)", "#f0efec"),
              (5.3, 12.45, "Hardware accelerator  (Verilog  →  45 nm ASIC)", "#e8f1fc")]
    for x0, x1, label, fill in groups:
        ax.add_patch(FancyBboxPatch((x0, 0.45), x1 - x0, 2.45, boxstyle="round,pad=0,rounding_size=0.12",
                                    fc=fill, ec="none"))
        ax.text(x0 + 0.15, 2.68, label, fontsize=12, fontweight="bold", color=SECONDARY, va="center")
    boxes = [(0.35, "Audio clip\n1 s, 16 kHz"), (1.95, "MFCC features\n25 × 10 = 250"),
             (3.55, "Normalize +\nquantize to INTn"), (5.55, "FC layer 1\n250 → 32"),
             (7.25, "ReLU +\nshift requant"), (8.95, "FC layer 2\n32 → 6"),
             (10.65, "Argmax\n→ word index")]
    for i, (x, label) in enumerate(boxes):
        ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0,rounding_size=0.08",
                                    fc="#ffffff", ec=BASELINE, lw=1))
        ax.text(x + w / 2, y + h / 2, label, ha="center", va="center", fontsize=11, color=PRIMARY)
        if i < len(boxes) - 1:
            nx = boxes[i + 1][0]
            ax.annotate("", xy=(nx - 0.04, y + h / 2), xytext=(x + w + 0.04, y + h / 2),
                        arrowprops=dict(arrowstyle="-|>", color=MUTED, lw=1.4, mutation_scale=14))
    ax.text(8.875, 0.82, "One shared MAC unit  ·  weights in on-chip ROM  ·  bit width BW = 8 or 4",
            ha="center", va="center", fontsize=10.5, color=SECONDARY)
    ax.text(2.575, 0.82, "Feature extraction stays in software", ha="center", va="center",
            fontsize=10.5, color=SECONDARY)
    ax.text(12.45, 0.18, "Words: " + ", ".join(words), ha="right", fontsize=10, color=MUTED)
    save(fig, "01_pipeline.png")


def fig_mfcc(d, words):
    X, y = d["X_test"], d["y_test"]
    fig, axes = plt.subplots(1, len(words), figsize=(12.6, 3.6), sharey=True, layout="constrained")
    for k, (ax, word) in enumerate(zip(axes, words)):
        Xk = X[y == k]
        typical = Xk[np.argmin(((Xk - Xk.mean(axis=0)) ** 2).sum(axis=1))]
        im = ax.imshow(typical.reshape(C.N_FRAMES, C.N_MFCC).T, origin="lower", aspect="auto",
                       cmap=DIV, vmin=-3, vmax=3, extent=(0, 1000, -0.5, C.N_MFCC - 0.5))
        ax.set_title(f"“{word}”", loc="center", fontsize=12)
        ax.set_xticks([0, 500, 1000])
        ax.set_xlabel("time (ms)")
        for s in ax.spines.values():
            s.set_visible(False)
    axes[0].set_ylabel("MFCC coefficient")
    cb = fig.colorbar(im, ax=axes, shrink=0.85, pad=0.01)
    cb.set_label("normalized value", color=SECONDARY)
    cb.outline.set_visible(False)
    fig.suptitle("What the network sees: 250 MFCC features per 1-second clip",
                 x=0.01, ha="left", fontsize=14, fontweight="bold")
    save(fig, "02_mfcc_examples.png")


def fig_training(history):
    fig, (a, b) = plt.subplots(1, 2, figsize=(12.6, 4.4), sharey=True, layout="constrained",
                               gridspec_kw={"width_ratios": [2, 1]})
    fp = [(e, v) for m, e, v in history if m == "FP32"]
    a.plot(*zip(*[(e, 100 * v) for e, v in fp]), color=PREC_COLOR["FP32"], lw=2,
           solid_capstyle="round")
    a.set_title("FP32 training: validation accuracy")
    a.set_xlabel("epoch")
    for name in ("INT8-QAT", "INT4-QAT"):
        pts = [(e, 100 * v) for m, e, v in history if m == name]
        if not pts:
            continue
        color = PREC_COLOR[precision_of(name)]
        b.plot(*zip(*pts), color=color, lw=2, solid_capstyle="round", label=precision_of(name))
        b.plot(*pts[-1], "o", ms=8, color=color, mec=SURFACE, mew=2)
        b.annotate(precision_of(name), pts[-1], xytext=(8, 0), textcoords="offset points",
                   va="center", color=SECONDARY, fontsize=10.5)
    b.set_title("Quantization-aware fine-tuning")
    b.set_xlabel("epoch  (0 = plain rounding, PTQ)")
    b.legend(loc="lower right", fontsize=10.5)
    for ax in (a, b):
        recessive_grid(ax)
        percent_axis(ax)
        ax.yaxis.set_major_locator(matplotlib.ticker.MultipleLocator(5))
    save(fig, "03_training_curves.png")


def fig_accuracy_all(rows):
    names = [r["model"] for r in rows]
    vals = [100 * float(r["test_acc"]) for r in rows]
    labels = [n.replace("-", " · ") for n in names]
    fig, ax = plt.subplots(figsize=(10, 4.2), layout="constrained")
    pos = np.arange(len(rows))[::-1]
    ax.set_yticks(pos, labels, fontsize=11.5)
    ax.set_xlim(0, 100)
    ax.set_ylim(-0.6, len(rows) - 0.4)
    percent_axis(ax, "x")
    recessive_grid(ax, "x")
    ax.set_title("Test accuracy of every model (integer models run bit-exact)")
    for p, v in zip(pos, vals):
        ax.text(v + 1, p, f"{v:.1f}%", va="center", fontsize=11, color=PRIMARY)
    handles = [plt.Line2D([], [], ls="", marker="s", ms=9, color=PREC_COLOR[k], label=k)
               for k in ("FP32", "INT8", "INT4")]
    ax.legend(handles=handles, loc="lower right", fontsize=10.5, bbox_to_anchor=(1.0, 1.0),
              ncol=3, borderaxespad=0.2)
    draw_bars(ax, pos, vals, [PREC_COLOR[precision_of(n)] for n in names], horizontal=True)
    save(fig, "04_accuracy_all_models.png")


def fig_accuracy_vs_memory(rows, chosen_method):
    picked = [r for r in rows if r["model"] == "FP32"]
    for bits in C.BIT_WIDTHS:
        picked += [r for r in rows if r["model"] == f"INT{bits}-{chosen_method[bits]}"]
    names = [precision_of(r["model"]) for r in picked]
    acc = [100 * float(r["test_acc"]) for r in picked]
    mem = [int(r["weight_memory_bytes"]) / 1024 for r in picked]
    colors = [PREC_COLOR[n] for n in names]
    fig, (a, b) = plt.subplots(1, 2, figsize=(12.6, 4.4), layout="constrained")
    x = np.arange(len(names))
    for ax, vals, title, fmt, top in (
            (a, acc, "Test accuracy", "{:.1f}%", 112),
            (b, mem, "Weight memory (KB)", "{:g} KB", max(mem) * 1.15)):
        ax.set_xticks(x, names, fontsize=12)
        ax.set_xlim(-0.6, len(names) - 0.4)
        ax.set_ylim(0, top)
        if ax is a:
            ax.set_yticks(range(0, 101, 20))
        ax.set_title(title)
        recessive_grid(ax)
        for xi, v in zip(x, vals):
            ax.annotate(fmt.format(v), (xi, v), xytext=(0, 5), textcoords="offset points",
                        ha="center", fontsize=11.5, color=PRIMARY)
        draw_bars(ax, x, vals, colors, horizontal=False)
    percent_axis(a)
    fig.suptitle("Lower precision: 4–8× less weight memory for a small accuracy cost",
                 x=0.01, ha="left", fontsize=14, fontweight="bold")
    save(fig, "05_accuracy_vs_memory.png")


def fig_weight_hist(W1_float):
    fig, axes = plt.subplots(1, 3, figsize=(12.6, 3.8), layout="constrained")
    a = axes[0]
    a.hist(W1_float.ravel(), bins=80, color=PREC_COLOR["FP32"], ec=SURFACE, lw=0.4)
    a.set_title("FP32: continuous values")
    a.set_xlabel("weight value")
    for ax, bits in zip(axes[1:], C.BIT_WIDTHS):
        m, _ = Q.load_int_model(C.RESULTS_DIR / f"qmodel_int{bits}.npz")
        q = Q.qmax(bits)
        levels, counts = np.unique(m["W1"], return_counts=True)
        width = 0.8 if bits <= 4 else 1.0
        ax.bar(levels, counts, width=width, color=PREC_COLOR[f"INT{bits}"], ec=SURFACE,
               lw=0.4 if bits > 4 else 2)
        ax.set_xlim(-q - 1, q + 1)
        ax.set_title(f"INT{bits}: {2 * q + 1} integer levels (−{q} … {q})")
        ax.set_xlabel("integer weight")
    axes[0].set_ylabel("number of weights")
    for ax in axes:
        recessive_grid(ax)
    save(fig, "06_weight_histograms.png")


def fig_confusion(name, words):
    path = C.RESULTS_DIR / f"confusion_{name}.csv"
    with open(path) as f:
        cm = np.array([[int(v) for v in row[1:]] for row in list(csv.reader(f))[1:]])
    pct = cm / np.maximum(cm.sum(axis=1, keepdims=True), 1)
    fig, ax = plt.subplots(figsize=(6.4, 5.6), layout="constrained")
    ax.imshow(pct, cmap=SEQ, vmin=0, vmax=1)
    n = len(words)
    ax.set_xticks(range(n), words)
    ax.set_yticks(range(n), words)
    ax.set_xlabel("predicted word")
    ax.set_ylabel("spoken word")
    ax.xaxis.set_label_position("top")
    ax.xaxis.tick_top()
    for s in ax.spines.values():
        s.set_visible(False)
    for i in range(n):
        for j in range(n):
            ax.text(j, i, f"{100 * pct[i, j]:.0f}", ha="center", va="center", fontsize=10.5,
                    color="#ffffff" if pct[i, j] > 0.45 else PRIMARY)
    ax.set_xticks(np.arange(n + 1) - 0.5, minor=True)
    ax.set_yticks(np.arange(n + 1) - 0.5, minor=True)
    ax.grid(which="minor", color=SURFACE, linewidth=2)
    ax.tick_params(which="minor", length=0)
    acc = 100 * np.trace(cm) / cm.sum()
    fig.suptitle(f"{name.replace('-', ' ')} confusion matrix (% of each row), accuracy {acc:.1f}%",
                 fontsize=12.5, fontweight="bold", x=0.02, ha="left")
    save(fig, f"07_confusion_{precision_of(name).lower()}.png")


# ---------------------------------------------------------------- terminal screenshots
TERM_BG, TERM_FG, TERM_CMD, TERM_BAR = "#0c0c0c", "#cccccc", "#f9f1a5", "#1f1f1f"


def _clean_log(text):
    text = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", text)
    text = text.replace(str(C.ROOT), "ee5113-kws-accelerator")
    lines = [ln.split("\r")[-1].rstrip() for ln in text.splitlines()]
    lines = [ln for ln in lines if not ln.startswith("[exited with code")]
    # Collapse progress output: keep the last download line and only finished clip counters
    downloads = [i for i, ln in enumerate(lines) if re.match(r"\s*downloaded\s+\d+ MB", ln)]
    keep = []
    for i, ln in enumerate(lines):
        m = re.match(r"\s*(train|val|test): (\d+)/(\d+) clips", ln)
        if (i in downloads and i != downloads[-1]) or (m and m.group(2) != m.group(3)):
            continue
        if not ln and keep and not keep[-1]:
            continue
        keep.append(ln)
    while keep and not keep[-1]:
        keep.pop()
    return keep


def terminal_png(command, lines, name, max_lines=46, wrap=122):
    wrapped = []
    for ln in lines:
        while len(ln) > wrap:
            wrapped.append(ln[:wrap])
            ln = "  " + ln[wrap:]
        wrapped.append(ln)
    if len(wrapped) > max_lines:
        head = max_lines // 2 - 2
        wrapped = wrapped[:head] + ["   ..."] + wrapped[-(max_lines - head - 1):]
    lh, top_bar = 0.19, 0.38
    height = top_bar + 0.22 + lh * (len(wrapped) + 1) + 0.12
    fig = plt.figure(figsize=(10.4, height))
    fig.patch.set_facecolor(TERM_BG)
    fig.add_artist(Rectangle((0, 1 - top_bar / height), 1, top_bar / height, fc=TERM_BAR,
                             ec="none", transform=fig.transFigure))
    tf = fig.dpi_scale_trans
    bar_y = height - top_bar / 2
    fig.text(0.22, bar_y, "Windows PowerShell", transform=tf, va="center", color="#cccccc",
             fontsize=10, family="Segoe UI")
    fig.text(10.15, bar_y, "—      □      ✕", transform=tf, ha="right", va="center",
             color="#9d9d9d", fontsize=11, family=["Segoe UI", "Segoe UI Symbol", "DejaVu Sans"])
    y = height - top_bar - 0.22
    mono = dict(family=["Consolas", "DejaVu Sans Mono"], fontsize=10, va="top", transform=tf)
    prompt = "PS C:\\ee5113-kws-accelerator> "
    fig.text(0.22, y, prompt, color=TERM_FG, **mono)
    fig.text(0.22 + 0.0765 * len(prompt), y, command, color=TERM_CMD, **mono)
    for i, ln in enumerate(wrapped, start=1):
        fig.text(0.22, y - i * lh, ln, color=TERM_FG, **mono)
    path = FIG_DIR / name
    fig.savefig(path, dpi=DPI, facecolor=TERM_BG)
    plt.close(fig)
    print(f"  {path.relative_to(C.ROOT)}")


def screenshots():
    steps = [("prepare_data.txt", "python python\\prepare_data.py", "screen_1_prepare_data.png"),
             ("train.txt", "python python\\train.py", "screen_2_train.png"),
             ("export_hw.txt", "python python\\export_hw.py", "screen_3_export_hw.png")]
    for log, cmd, out in steps:
        path = LOG_DIR / log
        if path.exists():
            terminal_png(cmd, _clean_log(path.read_text(errors="replace")), out)
        else:
            print(f"  (skipped {out}: no {path.relative_to(C.ROOT)})")
    params = C.HW_DIR / "int8" / "kws_params.vh"
    if params.exists():
        lines = params.read_text().splitlines()
        weights = (C.HW_DIR / "int8" / "weights.mem").read_text().splitlines()[:8]
        lines += ["", "PS C:\\ee5113-kws-accelerator> Get-Content weights\\int8\\weights.mem -TotalCount 8"]
        lines += weights
        terminal_png("Get-Content weights\\int8\\kws_params.vh", lines, "screen_4_hw_files.png")


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--features", default=str(C.FEATURES_FILE))
    args = ap.parse_args()
    FIG_DIR.mkdir(parents=True, exist_ok=True)

    d = np.load(args.features)
    words = [str(w) for w in d["words"]]
    with open(C.RESULTS_DIR / "results.csv") as f:
        rows = list(csv.DictReader(f))
    with open(C.RESULTS_DIR / "history.csv") as f:
        history = [(r["model"], int(r["epoch"]), float(r["val_acc"])) for r in csv.DictReader(f)]
    chosen = {int(r["bits"]): r["method"] for r in rows if r["exported"] == "yes"}

    print("Writing figures:")
    fig_pipeline(words)
    fig_mfcc(d, words)
    fig_training(history)
    fig_accuracy_all(rows)
    fig_accuracy_vs_memory(rows, chosen)
    fig_weight_hist(np.load(C.RESULTS_DIR / "float_weights.npz")["W1"])
    for b in C.BIT_WIDTHS:
        fig_confusion(f"INT{b}-{chosen[b]}", words)
    screenshots()


if __name__ == "__main__":
    sys.exit(main())
