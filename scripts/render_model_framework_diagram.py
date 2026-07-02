#!/usr/bin/env python3
"""Submission-only model framework diagram (no overlapping elements)."""
from __future__ import annotations

import argparse
from pathlib import Path

import matplotlib.pyplot as plt
from matplotlib.patches import FancyArrowPatch, FancyBboxPatch, Polygon, Rectangle

plt.rcParams["font.sans-serif"] = ["Noto Sans CJK JP", "DejaVu Sans"]
plt.rcParams["axes.unicode_minus"] = False

SCRIPT_DIR = Path(__file__).resolve().parent
GC2026_ROOT = SCRIPT_DIR.parent
FIGURES = GC2026_ROOT / "docs/meeting_delivery/figures"

C_BG = "#fafafa"
C_IN = "#fff8e1"
C_NN = "#bbdefb"
C_GEO = "#c8e6c9"
C_GATE = "#f8bbd0"
C_OUT = "#d1c4e9"
C_EDGE = "#37474f"
C_MUTED = "#607d8b"
C_CD = "#c62828"


def _box(ax, x, y, w, h, text, *, fc, fs=8.0, bold=False):
    ax.add_patch(FancyBboxPatch(
        (x, y), w, h, boxstyle="round,pad=0.03,rounding_size=0.07",
        facecolor=fc, edgecolor=C_EDGE, linewidth=1.2, zorder=2,
    ))
    ax.text(x + w / 2, y + h / 2, text, ha="center", va="center", fontsize=fs,
            fontweight="bold" if bold else "normal", multialignment="center", zorder=3)


def _arrow(ax, x0, y0, x1, y1, *, rad=0.0, zorder=4):
    ax.add_patch(FancyArrowPatch(
        (x0, y0), (x1, y1), arrowstyle="-|>", mutation_scale=13,
        color=C_MUTED, linewidth=1.5, connectionstyle=f"arc3,rad={rad}", zorder=zorder,
    ))


def render_framework(out_png: Path, dpi: int = 220) -> Path:
    fig, ax = plt.subplots(figsize=(14.0, 8.6), dpi=dpi, facecolor=C_BG)
    ax.set_facecolor(C_BG)
    ax.set_xlim(0, 14)
    ax.set_ylim(0, 8.6)
    ax.axis("off")

    # ── 标题区 y: 7.65–8.35 ──
    ax.text(7.0, 8.05, "提交模型框架  ·  holefill_adaptive_frame_gate_v2",
            ha="center", fontsize=15, fontweight="bold", color="#212121")
    ax.text(7.0, 7.65, "Enhancement Only  |  val565 CD = 14.870 mm  |  vs CG 17.552 (+2.68 mm)",
            ha="center", fontsize=9.5, color=C_MUTED)

    # ── 主流程 y: 5.85–6.85 ──
    y, h = 5.85, 1.0
    xs = [0.35, 1.78, 3.22, 4.66, 6.1, 7.52, 8.82, 10.05]
    ws = [1.25, 1.25, 1.25, 1.25, 1.25, 1.15, 1.05, 0.95]
    steps = [
        ("CGv2\n输入", C_IN, "2155 帧"),
        ("PD-LTS\nUVG-FT", C_NN, "去噪 · epoch 19"),
        ("Primary", C_GEO, "snap 1.0\nfill 0.6"),
        ("Frame Gate", C_GATE, "逐帧探测"),
        ("SuperPC", C_NN, "可选填洞"),
        ("Post SOR", C_GEO, "adaptive"),
        ("KNN", C_GEO, "颜色"),
        ("ENH", C_OUT, "输出"),
    ]
    for x, w, (t, c, s) in zip(xs, ws, steps):
        _box(ax, x, y, w, h, f"{t}\n{s}", fc=c, fs=7.5, bold=(t == "ENH"))
    for i in range(len(xs) - 1):
        _arrow(ax, xs[i] + ws[i] + 0.03, y + h / 2, xs[i + 1] - 0.03, y + h / 2)

    # HE 评估（主流程右侧，箭头 ENH → HE）
    _box(ax, 11.35, 5.85, 1.55, 1.0, "HE\n评估参考", fc="#eceff1", fs=8)
    _arrow(ax, 11.0, 6.35, 11.35, 6.35, rad=0.0)

    # ── Gate 分支区 y: 3.15–4.75 ──
    ax.text(7.0, 4.85, "Frame Gate 分支（est_add_ratio）", ha="center", fontsize=9.5,
            fontweight="bold", color="#ad1457")
    gx, gy = 7.0, 4.05
    ax.add_patch(Polygon(
        [(gx, gy + 0.45), (gx + 0.5, gy), (gx, gy - 0.45), (gx - 0.5, gy)],
        closed=True, facecolor=C_GATE, edgecolor=C_EDGE, linewidth=1.1, zorder=2,
    ))
    ax.text(gx, gy, "Gate", ha="center", va="center", fontsize=8, fontweight="bold", zorder=3)
    _arrow(ax, 5.22, 5.85, gx, gy + 0.48, rad=0.0)

    tiers = [(4.05, "skip", "仅 Primary\nVH/VL skip", "#ffcdd2"),
             (6.2, "lite", "fill 0.25\nmax 10%", "#fff9c4"),
             (8.35, "full", "fill 0.6\nmax 15%", "#c8e6c9")]
    for tx, name, desc, col in tiers:
        _box(ax, tx, 3.05, 1.45, 0.85, f"{name}\n{desc}", fc=col, fs=7.2)
        _arrow(ax, gx, gy - 0.48, tx + 0.72, 3.92, rad=0.15 if tx < gx else -0.15)
    _arrow(ax, 9.8, 3.47, 7.52 + 0.3, 5.85, rad=-0.22)

    # ── 说明区 y: 1.65–2.55（与 gate 框分离） ──
    notes = [
        "① 神经网络去噪一定在最前（非先 fill 再 denoise）",
        "② Primary 固定 snap → fill；SuperPC 支路 fill → snap",
        "③ CG 点不删 · 颜色 KNN 自 CG · gc_baseline Chamfer vs HE",
    ]
    for i, line in enumerate(notes):
        ax.text(0.45, 2.45 - i * 0.38, line, fontsize=8.2, color="#455a64")

    # 图例
    for i, (lab, c) in enumerate([("NN", C_NN), ("几何", C_GEO), ("门控", C_GATE), ("输出", C_OUT)]):
        bx = 10.55 + i * 0.85
        ax.add_patch(Rectangle((bx, 1.82), 0.32, 0.32, facecolor=c, edgecolor=C_EDGE, lw=0.7))
        ax.text(bx + 0.42, 1.98, lab, fontsize=7.5, va="center", color=C_EDGE)

    # 公式区 y: 0.45–1.25
    ax.add_patch(Rectangle((0.35, 0.45), 13.3, 0.85, facecolor="white", edgecolor="#cfd8dc", linewidth=0.9))
    ax.text(
        7.0, 0.87,
        r"$\hat{P}_{ENH} = \mathcal{R}_\phi(\mathcal{G}^{FT}_\theta(P_{CG}),\, P_{CG},\, \mathcal{G}^{SP}(P_{CG}))$"
        "\nFT PD-LTS + CG-preserving refine + gated SuperPC hole-fill",
        ha="center", va="center", fontsize=9, color="#37474f", linespacing=1.35,
    )

    out_png.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_png, bbox_inches="tight", facecolor=C_BG, pad_inches=0.1)
    plt.close(fig)
    return out_png


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--out-dir", type=Path, default=FIGURES)
    p.add_argument("--dpi", type=int, default=220)
    args = p.parse_args()
    print(render_framework(args.out_dir / "diagram_model_framework.png", dpi=args.dpi))


if __name__ == "__main__":
    main()
