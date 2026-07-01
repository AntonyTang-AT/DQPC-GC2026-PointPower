#!/usr/bin/env python3
"""Render qualitative val565 comparison figure (paper-style) for GC2026 methods."""
from __future__ import annotations

import argparse
import csv
import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import matplotlib.pyplot as plt
import numpy as np
from matplotlib.patches import Rectangle
from mpl_toolkits.axes_grid1.inset_locator import inset_axes

SCRIPT_DIR = Path(__file__).resolve().parent
GC2026_ROOT = SCRIPT_DIR.parent
sys.path.insert(0, str(SCRIPT_DIR))

from uvg_io import read_ply_xyz_rgb  # noqa: E402

METHOD_DIRS = {
    "cg": "data/raw/UVG-CWI-DQPC",  # resolved per-sequence below
    "he": "data/raw/UVG-CWI-DQPC",
    "superpc_blend_cg": "output/submission_candidate",
    "pdlts_raw": "output/pdlts_val565/light",
    "pdlts_vh_snap0": "output/enh_refine_val565_selection/vh_snap0",
}

METRIC_CSVS = {
    "superpc_blend_cg": "docs/meeting_delivery/metrics/01_superpc_blend_cg_kitti360_vx3.0_val565.csv",
    "pdlts_raw": "docs/meeting_delivery/metrics/04_pdlts_raw_val565.csv",
    "pdlts_vh_snap0": "docs/meeting_delivery/metrics/02_pdlts_vh_snap0_val565.csv",
}

PANELS = [
    ("cg", "CG (input)", None),
    ("superpc_blend_cg", "SuperPC blend_cg", "superpc_blend_cg"),
    ("pdlts_raw", "PD-LTS raw", "pdlts_raw"),
    ("pdlts_vh_snap0", "PD-LTS vh_snap0", "pdlts_vh_snap0"),
    ("he", "HE (reference)", None),
]


@dataclass
class FramePick:
    sequence: str
    frame_idx: str
    enh_name: str
    cg_name: str
    he_name: str
    chamfer: Dict[str, float]
    gap_superpc_minus_vh: float


def load_metric_rows(csv_name: str) -> Dict[Tuple[str, str], dict]:
    path = GC2026_ROOT / csv_name
    out: Dict[Tuple[str, str], dict] = {}
    with open(path, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            key = (row["sequence"], row["frame"])
            out[key] = row
    return out


def pick_best_frame() -> FramePick:
    sp = load_metric_rows(METRIC_CSVS["superpc_blend_cg"])
    vh = load_metric_rows(METRIC_CSVS["pdlts_vh_snap0"])
    raw = load_metric_rows(METRIC_CSVS["pdlts_raw"])
    best_key = None
    best_gap = -1.0
    for key in sp:
        gap = float(sp[key]["chamfer_distance"]) - float(vh[key]["chamfer_distance"])
        if gap > best_gap:
            best_gap = gap
            best_key = key
    seq, fidx = best_key
    row = sp[best_key]
    enh = row["test_file"]
    cg = enh.replace("_ENH_", "_CG_")
    he = row["gt_file"]
    return FramePick(
        sequence=seq,
        frame_idx=fidx,
        enh_name=enh,
        cg_name=cg,
        he_name=he,
        chamfer={
            "superpc_blend_cg": float(sp[best_key]["chamfer_distance"]),
            "pdlts_raw": float(raw[best_key]["chamfer_distance"]),
            "pdlts_vh_snap0": float(vh[best_key]["chamfer_distance"]),
        },
        gap_superpc_minus_vh=best_gap,
    )


def resolve_ply(root: Path, panel_key: str, pick: FramePick) -> Path:
    seq = pick.sequence
    if panel_key == "cg":
        return root / "data/raw/UVG-CWI-DQPC" / seq / "consumer-grade_capture_system/CG/15fps" / pick.cg_name
    if panel_key == "he":
        return root / "data/raw/UVG-CWI-DQPC" / seq / "high-end_capture_system/HE/15fps" / pick.he_name
    rel = METHOD_DIRS[panel_key]
    return root / rel / seq / pick.enh_name


def subsample(xyz: np.ndarray, rgb: np.ndarray, n: int, seed: int) -> Tuple[np.ndarray, np.ndarray]:
    if xyz.shape[0] <= n:
        return xyz, rgb
    rng = np.random.RandomState(seed)
    idx = rng.choice(xyz.shape[0], size=n, replace=False)
    return xyz[idx], rgb[idx]


def mask_box(xyz: np.ndarray, center: np.ndarray, half: np.ndarray) -> np.ndarray:
    lo = center - half
    hi = center + half
    return np.all((xyz >= lo) & (xyz <= hi), axis=1)


def choose_zoom_boxes(he_xyz: np.ndarray, sp_xyz: np.ndarray, vh_xyz: np.ndarray) -> Tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """Pick two ROIs: (1) high SuperPC error vs vh, (2) secondary detail region."""
    mins = np.percentile(he_xyz, 5, axis=0)
    maxs = np.percentile(he_xyz, 95, axis=0)
    span = maxs - mins
    # Grid search on XY for region where superpc deviates most from vh (proxy: distance to vh)
    from scipy.spatial import cKDTree

    tree_vh = cKDTree(vh_xyz.astype(np.float64))
    d_sp, _ = tree_vh.query(sp_xyz.astype(np.float64), k=1, workers=-1)
    best_score = -1.0
    best_center = mins + 0.5 * span
    half1 = span * np.array([0.08, 0.08, 0.12])
    half1[2] = max(half1[2], 80.0)
    for ux in np.linspace(0.25, 0.75, 5):
        for uy in np.linspace(0.2, 0.8, 7):
            center = mins + span * np.array([ux, uy, 0.55])
            m = mask_box(sp_xyz, center, half1)
            if m.sum() < 200:
                continue
            score = float(np.mean(d_sp[m]))
            if score > best_score:
                best_score = score
                best_center = center
    # second box: lower scene (car / foreground proxy)
    center2 = mins + span * np.array([0.5, 0.35, 0.25])
    half2 = span * np.array([0.12, 0.06, 0.08])
    half2[2] = max(half2[2], 50.0)
    return best_center, half1, center2, half2


def project_points(xyz: np.ndarray, elev: float, azim: float) -> Tuple[np.ndarray, np.ndarray]:
    elev_r = np.deg2rad(elev)
    azim_r = np.deg2rad(azim)
    # camera looks toward origin-ish; simple orthographic on rotated coords
    c, s = np.cos(azim_r), np.sin(azim_r)
    x1 = xyz[:, 0] * c - xyz[:, 1] * s
    y1 = xyz[:, 0] * s + xyz[:, 1] * c
    ce, se = np.cos(elev_r), np.sin(elev_r)
    y2 = y1 * ce - xyz[:, 2] * se
    return x1, y2


def draw_panel(
    ax,
    xyz: np.ndarray,
    rgb: np.ndarray,
    title: str,
    elev: float,
    azim: float,
    chamfer_mm: Optional[float],
    boxes: Optional[List[Tuple[np.ndarray, np.ndarray]]] = None,
    s: float = 0.12,
) -> None:
    px, py = project_points(xyz, elev, azim)
    ax.scatter(px, py, c=np.clip(rgb, 0, 1), s=s, linewidths=0, rasterized=True)
    ax.set_aspect("equal")
    ax.axis("off")
    subtitle = title if chamfer_mm is None else f"{title}\nCD={chamfer_mm:.2f} mm"
    ax.set_title(subtitle, fontsize=9, pad=4)
    if boxes:
        for center, half in boxes:
            cx, cy = project_points(center.reshape(1, 3), elev, azim)
            # project box corners for rectangle in 2D (approx using half extents in projected space)
            corners = np.array(
                [
                    center + half * np.array([sx, sy, sz])
                    for sx in (-1, 1)
                    for sy in (-1, 1)
                    for sz in (-1, 1)
                ]
            )
            cpx, cpy = project_points(corners, elev, azim)
            x0, x1 = cpx.min(), cpx.max()
            y0, y1 = cpy.min(), cpy.max()
            ax.add_patch(Rectangle((x0, y0), x1 - x0, y1 - y0, fill=False, edgecolor="red", linewidth=1.2))


def draw_inset(
    fig,
    bbox_ax,
    xyz: np.ndarray,
    rgb: np.ndarray,
    center: np.ndarray,
    half: np.ndarray,
    elev: float,
    azim: float,
    loc: str,
) -> None:
    m = mask_box(xyz, center, half)
    if m.sum() < 50:
        return
    sub_xyz, sub_rgb = xyz[m], rgb[m]
    iax = inset_axes(bbox_ax, width="38%", height="38%", loc=loc, borderpad=0.8)
    px, py = project_points(sub_xyz, elev, azim)
    iax.scatter(px, py, c=np.clip(sub_rgb, 0, 1), s=0.35, linewidths=0, rasterized=True)
    iax.set_aspect("equal")
    iax.axis("off")
    for spine in iax.spines.values():
        spine.set_edgecolor("red")
        spine.set_linewidth(1.5)
        spine.set_visible(True)


def render_figure(
    pick: FramePick,
    out_png: Path,
    out_json: Path,
    max_points: int,
    elev: float,
    azim: float,
) -> None:
    clouds: Dict[str, Tuple[np.ndarray, np.ndarray]] = {}
    for key, _, _ in PANELS:
        path = resolve_ply(GC2026_ROOT, key, pick)
        if not path.is_file():
            raise FileNotFoundError(path)
        xyz, rgb = read_ply_xyz_rgb(str(path), max_points=max_points, rng=np.random.RandomState(42))
        clouds[key] = (xyz, rgb)

    he_xyz = clouds["he"][0]
    sp_xyz = clouds["superpc_blend_cg"][0]
    vh_xyz = clouds["pdlts_vh_snap0"][0]
    c1, h1, c2, h2 = choose_zoom_boxes(he_xyz, sp_xyz, vh_xyz)
    boxes = [(c1, h1), (c2, h2)]

    fig, axes = plt.subplots(1, len(PANELS), figsize=(16, 3.8), dpi=200)
    fig.subplots_adjust(wspace=0.02, left=0.01, right=0.99, top=0.82, bottom=0.06)
    fig.suptitle(
        f"Qualitative comparison — {pick.sequence} / {pick.enh_name}  "
        f"(val565; SuperPC−vh gap={pick.gap_superpc_minus_vh:.2f} mm)",
        fontsize=11,
        y=0.98,
    )

    for ax, (key, title, metric_key) in zip(axes, PANELS):
        xyz, rgb = clouds[key]
        cd = pick.chamfer.get(metric_key) if metric_key else None
        draw_panel(ax, xyz, rgb, title, elev, azim, cd, boxes=boxes, s=0.1 if key == "he" else 0.12)
        draw_inset(fig, ax, xyz, rgb, c1, h1, elev, azim, loc="upper left")
        draw_inset(fig, ax, xyz, rgb, c2, h2, elev, azim, loc="lower right")

    out_png.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_png, bbox_inches="tight", facecolor="white")
    plt.close(fig)

    meta = {
        "sequence": pick.sequence,
        "frame_index_val565": pick.frame_idx,
        "enh_filename": pick.enh_name,
        "cg_filename": pick.cg_name,
        "he_filename": pick.he_name,
        "chamfer_mm": pick.chamfer,
        "gap_superpc_minus_vh": pick.gap_superpc_minus_vh,
        "view": {"elev": elev, "azim": azim},
        "max_points": max_points,
        "zoom_boxes_mm": [
            {"center": c1.tolist(), "half": h1.tolist()},
            {"center": c2.tolist(), "half": h2.tolist()},
        ],
    }
    out_json.write_text(json.dumps(meta, indent=2), encoding="utf-8")
    print(json.dumps({"out_png": str(out_png), "meta": meta}, indent=2))


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--out-dir", default=str(GC2026_ROOT / "docs/meeting_delivery/figures"))
    p.add_argument("--sequence", default="")
    p.add_argument("--frame-index", default="", help="val565 CSV frame column (not filename suffix)")
    p.add_argument("--auto-pick", action="store_true", help="pick frame with max superpc - vh_snap0 chamfer")
    p.add_argument("--max-points", type=int, default=120000)
    p.add_argument("--elev", type=float, default=18.0)
    p.add_argument("--azim", type=float, default=-68.0)
    args = p.parse_args()

    if args.auto_pick or not (args.sequence and args.frame_index):
        pick = pick_best_frame()
    else:
        sp = load_metric_rows(METRIC_CSVS["superpc_blend_cg"])
        key = (args.sequence, args.frame_index)
        row = sp[key]
        pick = FramePick(
            sequence=args.sequence,
            frame_idx=args.frame_index,
            enh_name=row["test_file"],
            cg_name=row["test_file"].replace("_ENH_", "_CG_"),
            he_name=row["gt_file"],
            chamfer={
                "superpc_blend_cg": float(row["chamfer_distance"]),
                "pdlts_raw": float(load_metric_rows(METRIC_CSVS["pdlts_raw"])[key]["chamfer_distance"]),
                "pdlts_vh_snap0": float(load_metric_rows(METRIC_CSVS["pdlts_vh_snap0"])[key]["chamfer_distance"]),
            },
            gap_superpc_minus_vh=float(row["chamfer_distance"])
            - float(load_metric_rows(METRIC_CSVS["pdlts_vh_snap0"])[key]["chamfer_distance"]),
        )

    tag = pick.enh_name.replace(".ply", "")
    out_dir = Path(args.out_dir)
    out_png = out_dir / f"qualitative_{pick.sequence}_{pick.frame_idx}_{tag}.png"
    out_json = out_dir / f"qualitative_{pick.sequence}_{pick.frame_idx}_{tag}.json"
    render_figure(pick, out_png, out_json, args.max_points, args.elev, args.azim)


if __name__ == "__main__":
    main()
