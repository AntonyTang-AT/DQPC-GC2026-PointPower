#!/usr/bin/env python3
"""Per-point error heatmap (aligned distance to HE) for val565 qualitative figures."""
from __future__ import annotations

import argparse
import csv
import json
import os
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import matplotlib.pyplot as plt
import numpy as np
from matplotlib import cm
from matplotlib.patches import Rectangle
from mpl_toolkits.axes_grid1.inset_locator import inset_axes
from scipy.spatial import cKDTree

SCRIPT_DIR = Path(__file__).resolve().parent
GC2026_ROOT = SCRIPT_DIR.parent
sys.path.insert(0, str(SCRIPT_DIR))

from evaluate_gc_baseline_metrics import apply_transform, load_align_matrix  # noqa: E402
from render_val565_qualitative import (  # noqa: E402
    METRIC_CSVS,
    PANELS,
    FramePick,
    load_metric_rows,
    mask_box,
    pick_best_frame,
    project_points,
    resolve_ply,
)
from uvg_io import read_ply_xyz_rgb  # noqa: E402

HEATMAP_PANELS = [
    ("superpc_blend_cg", "SuperPC blend_cg", "superpc_blend_cg"),
    ("pdlts_raw", "PD-LTS raw", "pdlts_raw"),
    ("pdlts_vh_snap0", "PD-LTS vh_snap0", "pdlts_vh_snap0"),
    ("he", "HE (reference)", None),
]


def aligned_point_errors(
    test_ply: Path,
    he_ply: Path,
    sequence: str,
    max_points: int,
    seed: int,
) -> Tuple[np.ndarray, np.ndarray, float, float]:
    rng = np.random.RandomState(seed)
    test_xyz, test_rgb = read_ply_xyz_rgb(str(test_ply), max_points=max_points, rng=rng)
    he_xyz, _ = read_ply_xyz_rgb(str(he_ply), max_points=max(200_000, max_points), rng=rng)
    test_xyz = apply_transform(test_xyz.astype(np.float64), load_align_matrix(sequence)).astype(np.float32)
    tree_he = cKDTree(he_xyz.astype(np.float64))
    dist, _ = tree_he.query(test_xyz.astype(np.float64), k=1, workers=-1)
    dist = dist.astype(np.float32)
    accuracy = float(dist.mean())
    return test_xyz, dist, accuracy, float(dist.max())


def pick_frame(args) -> FramePick:
    if args.auto_pick or not (args.sequence and args.frame_index):
        return pick_best_frame()
    sp = load_metric_rows(METRIC_CSVS["superpc_blend_cg"])
    key = (args.sequence, args.frame_index)
    row = sp[key]
    vh = load_metric_rows(METRIC_CSVS["pdlts_vh_snap0"])
    raw = load_metric_rows(METRIC_CSVS["pdlts_raw"])
    return FramePick(
        sequence=args.sequence,
        frame_idx=args.frame_index,
        enh_name=row["test_file"],
        cg_name=row["test_file"].replace("_ENH_", "_CG_"),
        he_name=row["gt_file"],
        chamfer={
            "superpc_blend_cg": float(row["chamfer_distance"]),
            "pdlts_raw": float(raw[key]["chamfer_distance"]),
            "pdlts_vh_snap0": float(vh[key]["chamfer_distance"]),
        },
        gap_superpc_minus_vh=float(row["chamfer_distance"]) - float(vh[key]["chamfer_distance"]),
    )


def draw_error_panel(
    ax,
    xyz: np.ndarray,
    dist: np.ndarray,
    title: str,
    elev: float,
    azim: float,
    vmax: float,
    accuracy: float,
    boxes: Optional[List[Tuple[np.ndarray, np.ndarray]]] = None,
) -> None:
    px, py = project_points(xyz, elev, azim)
    colors = cm.get_cmap("turbo")(np.clip(dist / vmax, 0.0, 1.0))
    ax.scatter(px, py, c=colors, s=0.14, linewidths=0, rasterized=True)
    ax.set_aspect("equal")
    ax.axis("off")
    ax.set_title(f"{title}\nacc={accuracy:.2f} mm", fontsize=9, pad=4)
    if boxes:
        for center, half in boxes:
            corners = np.array(
                [center + half * np.array([sx, sy, sz]) for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)]
            )
            cpx, cpy = project_points(corners, elev, azim)
            ax.add_patch(
                Rectangle(
                    (cpx.min(), cpy.min()),
                    cpx.max() - cpx.min(),
                    cpy.max() - cpy.min(),
                    fill=False,
                    edgecolor="white",
                    linewidth=1.0,
                )
            )


def draw_error_inset(fig, bbox_ax, xyz, dist, center, half, elev, azim, vmax, loc: str) -> None:
    m = mask_box(xyz, center, half)
    if m.sum() < 50:
        return
    iax = inset_axes(bbox_ax, width="38%", height="38%", loc=loc, borderpad=0.8)
    sub_xyz, sub_dist = xyz[m], dist[m]
    px, py = project_points(sub_xyz, elev, azim)
    colors = cm.get_cmap("turbo")(np.clip(sub_dist / vmax, 0.0, 1.0))
    iax.scatter(px, py, c=colors, s=0.5, linewidths=0, rasterized=True)
    iax.set_aspect("equal")
    iax.axis("off")
    for spine in iax.spines.values():
        spine.set_edgecolor("white")
        spine.set_linewidth(1.2)
        spine.set_visible(True)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--out-dir", default=str(GC2026_ROOT / "docs/meeting_delivery/figures"))
    p.add_argument("--sequence", default="")
    p.add_argument("--frame-index", default="")
    p.add_argument("--auto-pick", action="store_true")
    p.add_argument("--max-points", type=int, default=100000)
    p.add_argument("--vmax-mm", type=float, default=50.0, help="Color scale max (mm to HE)")
    p.add_argument("--elev", type=float, default=18.0)
    p.add_argument("--azim", type=float, default=-68.0)
    args = p.parse_args()

    pick = pick_frame(args)
    he_path = GC2026_ROOT / "data/raw/UVG-CWI-DQPC" / pick.sequence / "high-end_capture_system/HE/15fps" / pick.he_name

    panel_data: Dict[str, Tuple[np.ndarray, np.ndarray, float]] = {}
    for key, _, metric_key in HEATMAP_PANELS:
        if key == "he":
            xyz, rgb = read_ply_xyz_rgb(str(he_path), max_points=args.max_points)
            panel_data[key] = (xyz, np.zeros(xyz.shape[0], dtype=np.float32), 0.0)
            continue
        ply = resolve_ply(GC2026_ROOT, key, pick)
        xyz, dist, acc, _ = aligned_point_errors(ply, he_path, pick.sequence, args.max_points, 42)
        panel_data[key] = (xyz, dist, acc)

    sp_xyz = panel_data["superpc_blend_cg"][0]
    vh_xyz = panel_data["pdlts_vh_snap0"][0]
    he_xyz = panel_data["he"][0]
    from render_val565_qualitative import choose_zoom_boxes

    c1, h1, c2, h2 = choose_zoom_boxes(he_xyz, sp_xyz, vh_xyz)
    boxes = [(c1, h1), (c2, h2)]

    fig, axes = plt.subplots(1, len(HEATMAP_PANELS), figsize=(14, 3.6), dpi=200)
    fig.subplots_adjust(wspace=0.03, left=0.02, right=0.88, top=0.80, bottom=0.08)
    fig.suptitle(
        f"Per-point error to HE (aligned) — {pick.sequence} / {pick.enh_name}",
        fontsize=11,
        y=0.98,
    )

    for ax, (key, title, metric_key) in zip(axes, HEATMAP_PANELS):
        xyz, dist, acc = panel_data[key]
        if key == "he":
            px, py = project_points(xyz, args.elev, args.azim)
            ax.scatter(px, py, c=np.clip(read_ply_xyz_rgb(str(he_path), max_points=args.max_points)[1], 0, 1),
                       s=0.12, linewidths=0, rasterized=True)
            ax.set_aspect("equal")
            ax.axis("off")
            ax.set_title(title, fontsize=9)
        else:
            draw_error_panel(ax, xyz, dist, title, args.elev, args.azim, args.vmax_mm, acc, boxes=boxes)
            draw_error_inset(fig, ax, xyz, dist, c1, h1, args.elev, args.azim, args.vmax_mm, "upper left")
            draw_error_inset(fig, ax, xyz, dist, c2, h2, args.elev, args.azim, args.vmax_mm, "lower right")

    cbar_ax = fig.add_axes([0.90, 0.15, 0.015, 0.65])
    sm = cm.ScalarMappable(cmap="turbo", norm=plt.Normalize(0, args.vmax_mm))
    sm.set_array([])
    cb = fig.colorbar(sm, cax=cbar_ax)
    cb.set_label("distance to HE (mm)", fontsize=9)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    tag = pick.enh_name.replace(".ply", "")
    out_png = out_dir / f"error_heatmap_{pick.sequence}_{pick.frame_idx}_{tag}.png"
    out_json = out_dir / f"error_heatmap_{pick.sequence}_{pick.frame_idx}_{tag}.json"
    fig.savefig(out_png, bbox_inches="tight", facecolor="white")
    plt.close(fig)

    meta = {
        "sequence": pick.sequence,
        "frame_index_val565": pick.frame_idx,
        "enh_filename": pick.enh_name,
        "vmax_mm": args.vmax_mm,
        "per_panel_accuracy_mm": {k: panel_data[k][2] for k, _, _ in HEATMAP_PANELS if k != "he"},
        "chamfer_from_csv": pick.chamfer,
    }
    out_json.write_text(json.dumps(meta, indent=2), encoding="utf-8")
    print(json.dumps({"out_png": str(out_png), "meta": meta}, indent=2))


if __name__ == "__main__":
    main()
