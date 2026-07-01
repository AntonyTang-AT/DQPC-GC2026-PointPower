#!/usr/bin/env python3
"""Zoom comparison: CG / HE / top models — ROI where CG-HE gap is largest."""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import matplotlib.pyplot as plt
import numpy as np
from matplotlib import cm
from matplotlib.patches import Rectangle
from scipy.spatial import cKDTree

SCRIPT_DIR = Path(__file__).resolve().parent
GC2026_ROOT = SCRIPT_DIR.parent
sys.path.insert(0, str(SCRIPT_DIR))

from evaluate_gc_baseline_metrics import apply_transform, eval_aligned_pair, load_align_matrix  # noqa: E402
from render_val565_qualitative import mask_box, project_points  # noqa: E402
from render_val565_zoom_utils import (  # noqa: E402
    draw_err_zoom,
    projected_box_rect,
    scene_bounds,
    set_zoom_limits,
)
from uvg_io import read_ply_xyz_rgb  # noqa: E402

THRESHOLDS = (10.0, 20.0, 30.0, 50.0)

MODEL_DIRS = {
    "cg": None,
    "he": None,
    "ft_density": GC2026_ROOT / "output/pdlts_finetune_uvg/val565_refine/pdlts_light_snap1_fill0.6_density",
    "line_b_holefill": GC2026_ROOT / "output/ft_val565_fusion/holefill_first_fill0.6_post25_density",
    "superpc_blend": GC2026_ROOT / "output/submission_candidate",
    "holefill_lite": GC2026_ROOT / "output/ft_val565_fusion/holefill_lite_fill0.25_max10pct_adaptive_post25",
    "frame_gate_v2": GC2026_ROOT / "output/ft_val565_fusion/holefill_adaptive_frame_gate_v2",
}


def paths_for_frame(sequence: str, cg_name: str) -> Dict[str, Path]:
    enh = cg_name.replace("_CG_", "_ENH_")
    he_name = enh.replace("_ENH_", "_HE_")
    base = GC2026_ROOT / "data/raw/UVG-CWI-DQPC" / sequence
    out = {
        "cg": base / "consumer-grade_capture_system/CG/15fps" / cg_name,
        "he": base / "high-end_capture_system/HE/15fps" / he_name,
    }
    for key, root in MODEL_DIRS.items():
        if root is not None:
            out[key] = root / sequence / enh
    return out


def align_xyz(xyz: np.ndarray, sequence: str) -> np.ndarray:
    return apply_transform(xyz.astype(np.float64), load_align_matrix(sequence)).astype(np.float32)


def cg_point_error(cg_xyz: np.ndarray, he_xyz: np.ndarray) -> np.ndarray:
    tree = cKDTree(he_xyz.astype(np.float64))
    dist, _ = tree.query(cg_xyz.astype(np.float64), k=1, workers=-1)
    return dist.astype(np.float32)


def find_cg_he_gap_roi(
    cg_xyz: np.ndarray,
    he_xyz: np.ndarray,
    cg_err: np.ndarray,
    he_err_on_cg: np.ndarray,
) -> Tuple[np.ndarray, np.ndarray, dict]:
    """ROI on body surface where CG deviates from HE (exclude outlier floaters)."""
    gap = cg_err - he_err_on_cg
    cap = float(np.percentile(cg_err, 92))
    valid = cg_err <= max(cap, 25.0)
    score_pts = np.where(valid, cg_err + np.maximum(gap, 0.0) * 1.2, 0.0)
    mins, maxs = scene_bounds(cg_xyz[valid] if np.any(valid) else cg_xyz)
    span = maxs - mins
    half = np.maximum(span * np.array([0.045, 0.045, 0.07]), np.array([14.0, 14.0, 28.0]))
    best_score = -1.0
    best_center = mins + 0.5 * span
    best_meta: dict = {}
    for ux in np.linspace(0.28, 0.72, 9):
        for uy in np.linspace(0.22, 0.78, 10):
            for uz in (0.42, 0.52, 0.62):
                center = mins + span * np.array([ux, uy, uz])
                m = mask_box(cg_xyz, center, half) & valid
                n = int(m.sum())
                if n < 120:
                    continue
                sc = float(np.mean(score_pts[m]))
                ce = float(np.mean(cg_err[m]))
                if sc > best_score and 12.0 < ce < cap:
                    best_score = sc
                    best_center = center.copy()
                    best_meta = {
                        "mean_cg_err_mm": ce,
                        "mean_gap_mm": float(np.mean(gap[m])),
                        "n_pts": n,
                    }
    return best_center, half, best_meta


def draw_rgb_zoom_ax(ax, xyz, rgb, center, half, elev, azim, title, s=3.0):
    m = mask_box(xyz, center, half)
    sub_xyz, sub_rgb = xyz[m], rgb[m]
    px, py = project_points(sub_xyz, elev, azim)
    ax.scatter(px, py, c=np.clip(sub_rgb, 0, 1), s=s, linewidths=0, rasterized=True)
    set_zoom_limits(ax, xyz, center, half, elev, azim)
    ax.set_aspect("equal")
    ax.axis("off")
    ax.set_title(title, fontsize=8, fontweight="bold")


def ensure_lite_frame(sequence: str, cg_name: str, paths: Dict[str, Path]) -> Path:
    lite = paths.get("holefill_lite")
    if lite and lite.is_file():
        return lite
    # On-the-fly single-frame infer for visualization
    from enh_refine_config import resolve_preset
    from enh_refine_pipeline import apply_refine_stages, output_ply_path
    from uvg_io import write_ply_xyz_rgb

    out_root = GC2026_ROOT / "output/ft_val565_fusion/holefill_lite_fill0.25_max10pct_adaptive_post25"
    cg_path = str(paths["cg"])
    out_path = Path(output_ply_path(str(out_root), cg_path))
    if out_path.is_file():
        return out_path
    cfg = resolve_preset("holefill_lite_fill0.25_max10pct_adaptive_post25")
    cfg.extra = {**(cfg.extra or {}), "geometry_secondary_dir": str(MODEL_DIRS["superpc_blend"])}
    cg_xyz, cg_rgb = read_ply_xyz_rgb(cg_path)
    out_xyz, out_rgb, _ = apply_refine_stages(
        cg_xyz, cg_rgb, cfg, cg_path=cg_path,
        geometry_dir=str(GC2026_ROOT / "output/pdlts_finetune_uvg/val565/light"),
    )
    out_path.parent.mkdir(parents=True, exist_ok=True)
    write_ply_xyz_rgb(str(out_path), out_xyz, out_rgb)
    return out_path


def cd_for(path: Path, he_path: Path, cg_path: str, sequence: str) -> Optional[float]:
    if not path.is_file():
        return None
    try:
        m = eval_aligned_pair(str(path), str(he_path), sequence, THRESHOLDS, 0, 0)
        return float(m["chamfer_distance"])
    except Exception:
        return None


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--sequence", default="TrumanShow")
    p.add_argument("--cg-name", default="TrumanShow_UVG-CWI-DQPC_CG_15_0_170_0072.ply")
    p.add_argument("--out-dir", default=str(GC2026_ROOT / "output/ft_val565_fusion/figures"))
    p.add_argument("--max-points", type=int, default=180000)
    p.add_argument("--elev", type=float, default=16.0)
    p.add_argument("--azim", type=float, default=-72.0)
    p.add_argument("--vmax-mm", type=float, default=35.0)
    args = p.parse_args()

    paths = paths_for_frame(args.sequence, args.cg_name)

    rng = np.random.RandomState(0)
    he_xyz, he_rgb = read_ply_xyz_rgb(str(paths["he"]), max_points=max(args.max_points, 220000), rng=rng)
    cg_xyz, cg_rgb = read_ply_xyz_rgb(str(paths["cg"]), max_points=args.max_points, rng=rng)
    he_al = align_xyz(he_xyz, args.sequence)
    cg_al = align_xyz(cg_xyz, args.sequence)

    cg_err = cg_point_error(cg_al, he_al)
    center, half, roi_meta = find_cg_he_gap_roi(cg_al, he_al, cg_err, np.zeros_like(cg_err))

    panels: List[Tuple[str, str, Optional[str]]] = [
        ("cg", "CG (input)", None),
        ("he", "HE (reference)", None),
        ("ft_density", "ft density", "baseline"),
        ("frame_gate_v2", "frame gate v2", "#1 submit"),
        ("holefill_lite", "holefill lite", None),
        ("superpc_blend", "SuperPC blend_cg", None),
    ]

    cds: Dict[str, Optional[float]] = {}
    clouds: Dict[str, Tuple[np.ndarray, np.ndarray]] = {}
    errs: Dict[str, np.ndarray] = {}
    for key, _, _ in panels:
        if key == "cg":
            clouds[key] = (cg_al, cg_rgb)
        elif key == "he":
            clouds[key] = (he_al, he_rgb)
        else:
            pp = paths.get(key)
            if pp and pp.is_file():
                xyz, rgb = read_ply_xyz_rgb(str(pp), max_points=args.max_points, rng=rng)
                xyz = align_xyz(xyz, args.sequence)
                clouds[key] = (xyz, rgb)
                errs[key] = cg_point_error(xyz, he_al)
                cds[key] = cd_for(pp, paths["he"], str(paths["cg"]), args.sequence)
            else:
                clouds[key] = (np.zeros((0, 3)), np.zeros((0, 3)))
                cds[key] = None

    cds["cg"] = cd_for(paths["cg"], paths["he"], str(paths["cg"]), args.sequence)

    fig = plt.figure(figsize=(18, 10), dpi=200)
    gs = fig.add_gridspec(2, 6, height_ratios=[1.0, 1.15], hspace=0.28, wspace=0.12)
    fig.suptitle(
        f"{args.sequence} / {args.cg_name.replace('_CG_', ' frame ')}\n"
        f"Red ROI: CG farthest from HE (mean err={roi_meta.get('mean_cg_err_mm', 0):.1f} mm)",
        fontsize=11,
        y=0.97,
    )

    ax_ov1 = fig.add_subplot(gs[0, 0:2])
    ax_ov2 = fig.add_subplot(gs[0, 2:4])
    ax_e1 = fig.add_subplot(gs[0, 4])
    ax_e2 = fig.add_subplot(gs[0, 5])

    px, py = project_points(cg_al, args.elev, args.azim)
    norm = np.clip(cg_err / args.vmax_mm, 0, 1)
    ax_ov1.scatter(px, py, c=plt.colormaps["turbo"](norm), s=0.15, linewidths=0, rasterized=True)
    x0, x1, y0, y1 = projected_box_rect(center, half, args.elev, args.azim)
    for ax in (ax_ov1, ax_ov2):
        ax.add_patch(Rectangle((x0, y0), x1 - x0, y1 - y0, fill=False, edgecolor="#ff2222", linewidth=2.2))
    ax_ov1.set_aspect("equal")
    ax_ov1.axis("off")
    ax_ov1.set_title(f"CG error to HE (CD={cds.get('cg', 0):.1f} mm)", fontsize=9)

    px, py = project_points(he_al, args.elev, args.azim)
    ax_ov2.scatter(px, py, c=np.clip(he_rgb, 0, 1), s=0.18, linewidths=0, rasterized=True)
    ax_ov2.set_aspect("equal")
    ax_ov2.axis("off")
    ax_ov2.set_title("HE reference", fontsize=9)

    draw_err_zoom(ax_e1, cg_al, cg_err, center, half, args.elev, args.azim, "ROI CG err", vmax=args.vmax_mm, s=3.2)
    if "ft_density" in errs:
        draw_err_zoom(
            ax_e2, clouds["ft_density"][0], errs["ft_density"], center, half,
            args.elev, args.azim, f"ROI ft err CD={cds.get('ft_density', 0):.1f}", vmax=args.vmax_mm, s=3.2,
        )

    bottom_axes = [fig.add_subplot(gs[1, j]) for j in range(6)]
    for ax, (key, label, note) in zip(bottom_axes, panels):
        xyz, rgb = clouds[key]
        cd_s = cds.get(key)
        cd_txt = f" CD={cd_s:.1f}" if cd_s is not None else ""
        tag = f"\n{note}" if note else ""
        draw_rgb_zoom_ax(ax, xyz, rgb, center, half, args.elev, args.azim, f"{label}{cd_txt}{tag}", s=2.6)

    cbar_ax = fig.add_axes([0.92, 0.58, 0.012, 0.30])
    sm = cm.ScalarMappable(cmap="turbo", norm=plt.Normalize(0, args.vmax_mm))
    fig.colorbar(sm, cax=cbar_ax).set_label("dist to HE (mm)", fontsize=8)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    tag = args.cg_name.replace(".ply", "")
    out_png = out_dir / f"model_he_gap_zoom_{args.sequence}_{tag}.png"
    out_json = out_dir / f"model_he_gap_zoom_{args.sequence}_{tag}.json"
    fig.savefig(out_png, bbox_inches="tight", facecolor="white")
    plt.close(fig)

    meta = {
        "sequence": args.sequence,
        "cg_name": args.cg_name,
        "roi": roi_meta,
        "chamfer_mm": {k: v for k, v in cds.items() if v is not None},
        "paths": {k: str(v) for k, v in paths.items() if v},
    }
    out_json.write_text(json.dumps(meta, indent=2), encoding="utf-8")
    print(json.dumps({"out_png": str(out_png), "meta": meta}, indent=2))


if __name__ == "__main__":
    main()
