#!/usr/bin/env python3
"""Figures for the presentation deck (see docs/slides/README.md).

    python docs/slides/make_slide_figures.py      # writes work/slides/*.png (git-ignored)

- Extracts three figures from the final report (.docx): Figure 1 (the system), Figure 3 (the
  accelerator block diagram) and Figure 13 (the INT8 and INT4 layouts at the same scale).
- Redraws the layer-1 weight histograms (results/python/figures/06_weight_histograms.png) in the
  deck's colors, FP32 gray, INT8 blue, INT4 orange, the same as on every other slide. The panels
  have no titles: the slide labels them in its own type.
Needs matplotlib (python/requirements.txt).
"""
import shutil
import sys
import zipfile
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "python"))
import config as C  # noqa: E402
import quant as Q  # noqa: E402

OUT = ROOT / "work" / "slides"
REPORT = ROOT / "docs" / "report" / "EE5113_Final_Project_Report.docx"
REPORT_FIGURES = {
    "word/media/image1.png": "report_fig1_system.png",
    "word/media/image3.png": "report_fig3_block_diagram.png",
    "word/media/image16.png": "report_fig13_layouts_same_scale.png",
}
SURFACE, MUTED, GRID = "#FBFBF8", "#5B6577", "#D9DEE6"
COLOR = {"FP32": "#8A94A6", 8: "#2A78D6", 4: "#EB6834"}


def report_figures():
    with zipfile.ZipFile(REPORT) as z:
        for member, name in REPORT_FIGURES.items():
            with z.open(member) as src, open(OUT / name, "wb") as dst:
                shutil.copyfileobj(src, dst)
            print("wrote", OUT / name)


def weight_histograms():
    plt.rcParams.update({
        "font.family": "DejaVu Sans", "font.size": 15, "figure.facecolor": SURFACE,
        "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE, "axes.edgecolor": GRID,
        "xtick.color": MUTED, "ytick.color": MUTED, "xtick.labelcolor": MUTED, "ytick.labelcolor": MUTED,
        "axes.spines.top": False, "axes.spines.right": False, "axes.spines.left": False,
        "xtick.major.size": 0, "ytick.major.size": 0,
    })
    w1 = np.load(C.RESULTS_DIR / "float_weights.npz")["W1"]
    fig, axes = plt.subplots(1, 3, figsize=(12.6, 3.4), layout="constrained")
    axes[0].hist(w1.ravel(), bins=80, color=COLOR["FP32"], ec=SURFACE, lw=0.4)
    for ax, bits in zip(axes[1:], C.BIT_WIDTHS):
        m, _ = Q.load_int_model(C.RESULTS_DIR / f"qmodel_int{bits}.npz")
        q = Q.qmax(bits)
        levels, counts = np.unique(m["W1"], return_counts=True)
        ax.bar(levels, counts, width=0.8 if bits <= 4 else 1.0, color=COLOR[bits], ec=SURFACE,
               lw=0.4 if bits > 4 else 2)
        ax.set_xlim(-q - 1, q + 1)
    for ax in axes:
        ax.grid(axis="y", color=GRID, linewidth=0.8)
        ax.set_axisbelow(True)
    out = OUT / "weight_histograms_deck.png"
    fig.savefig(out, dpi=200)
    print("wrote", out)


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    report_figures()
    weight_histograms()
