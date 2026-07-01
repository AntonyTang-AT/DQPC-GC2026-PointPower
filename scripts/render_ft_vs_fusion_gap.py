#!/usr/bin/env python3
"""Visualize where fusion hurts vs ft density (worst val565 frame + ROI zoom)."""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Dict, Tuple

import matplotlib.pyplot as plt
import numpy as np
from matplotlib import cm
from matplotlib.patches import Rectangle
from scipy.spatial import cKDTree

SCRIPT_DIR = Path(__file__).resolve().parent
GC2026_ROOT = SCRIPT_DIR.parent
sys.path.insert(0, str(SCRIPT_DIR))

from evaluate_gc_baseline_metrics import apply_transform, load_align_matrix  # noqa: E402
from render_val565_qualitative import mask_box, project_points  # noqa: E402
from render_val565_zoom_utils import (  # noqa: E402
    draw_rgb_zoom,
    projected_box_rect,
    scene_bounds,
    set_zoom_limits,
)
from uvg_io import read_ply_xyz_rgb  # noqa: E402

FT_DENSITY = GC2026_ROOT / "output/pdlts_finetune_uvg/val565_refine/pdlts_light_snap1_fill0.6_density"
FUSION = GC2026_ROOT / "output/ft_val565_fusion/temporal_attn_hybrid_pdlts_superpc_snap1_fill0.6_density"
SUPERPC = GC2026_ROOT / "output/submission_candidate"
FT_EVAL = FT_DENSITY / "evaluation_gc_baseline_val565.json"
FU_EVAL = FUSION / "evaluation_gc_baseline_val565.json"


def cg_to_paths(cg_name: str, sequence: str) -> Tuple[Path, Path, Path, Path, Path]:
    enh = cg_name.replace("_CG_", "_ENH_")
    cg_path = GC2026_ROOT / "data/raw/UVG-CWI-DQPC" / sequence / "consumer-grade_capture_system/CG/15fps" / cg_name
    he_path = GC2026_ROOT / "data/raw/UVG-CWI-DQPC" / sequence / "high-end_capture_system/HE/15fps" / enh.replace("_ENH_", "_HE_")
    return (
        cg_path,
        he_path,
        FT_DENSITY / sequence / enh,
        FUSION / sequence / enh,
        SUPERPC / sequence / enh,
    )


def align_xyz(xyz: np.ndarray, sequence: str) -> np.ndarray:
    return apply_transform(xyz.astype(np.float64), load_align_matrix(sequence)).astype(np.float32)


def he_nn_error(he_xyz: np.ndarray, test_xyz: np.ndarray) -> np.ndarray:
    tree = cKDTree(test_xyz.astype(np.float64))
    dist, _ = tree.query(he_xyz.astype(np.float64), k=1, workers=-1)
    return dist.astype(np.float32)


def find_worst_frame() -> Tuple[str, str, float, dict, dict]:
    ft = json.load(open(FT_EVAL))
    fu = json.load(open(FU_EVAL))
    fm: Dict[str, dict] = {}
    for r in ft.get("records", []):
        fm[os.path.basename(r["cg_path"])] = r
    best = ("", "", 0.0, {}, {})
    for r in fu.get("records", []):
        cg = os.path.basename(r["cg_path"])
        if cg not in fm:
            continue
        delta = float(r["chamfer_distance"]) - float(fm[cg]["chamfer_distance"])
        if delta > best[2]:
            seq = r.get("sequence") or ""
            if not seq:
                for s in ("TrumanShow", "VictoryHeart", "VirtualLife"):
                    if f"/{s}/" in r.get("cg_path", ""):
                        seq = s
            best = (seq, cg, delta, fm[cg], r)
    return best


def find_he_worse_roi(
    he_xyz: np.ndarray,
    gap: np.ndarray,
    cg_xyz: np.ndarray,
) -> Tuple[np.ndarray, np.ndarray, dict]:
    mins, maxs = scene_bounds(cg_xyz)
    span = maxs - mins
    half = np.maximum(span * np.array([0.06, 0.06, 0.10]), np.array([20.0, 20.0, 40.0]))
    best_score = -1e9
    best_center = mins + 0.5 * span
    best_meta: dict = {}
    for ux in np.linspace(0.15, 0.85, 11):
        for uy in np.linspace(0.15, 0.85, 13):
            for uz in (0.35, 0.5, 0.65, 0.78):
                center = mins + span * np.array([ux, uy, uz])
                m = mask_box(he_xyz, center, half)
                n = int(m.sum())
                if n < 120:
                    continue
                g = gap[m]
                score = float(np.mean(g))
                if score > best_score:
                    best_score = score
                    best_center = center.copy()
                    best_meta = {
                        "mean_gap_mm": score,
                        "max_gap_mm": float(np.max(g)),
                        "n_he_pts": n,
                    }
    return best_center, half, best_meta


def draw_he_gap_overview(ax, he_xyz, he_rgb, gap, center, half, elev, azim, title, vmax=15.0, s=0.35):
    px, py = project_points(he_xyz, elev, azim)
    norm = np.clip(gap / max(vmax, 1e-6), 0.0, 1.0)
    ax.scatter(px, py, c=cm.get_cmap("YlOrRd")(norm), s=s, linewidths=0, rasterized=True)
    x0, x1, y0, y1 = projected_box_rect(center, half, elev, azim)
    ax.add_patch(Rectangle((x0, y0), x1 - x0, y1 - y0, fill=False, edgecolor="#ff2222", linewidth=2.2))
    ax.set_aspect("equal")
    ax.axis("off")
    ax.set_title(f"{title}\nmean gap={float(gap.mean()):.1f} mm", fontsize=8)


def draw_he_gap_zoom(ax, he_xyz, gap, center, half, elev, azim, title, vmax=15.0, s=4.0):
    m = mask_box(he_xyz, center, half)
    sub_xyz, sub_g = he_xyz[m], gap[m]
    px, py = project_points(sub_xyz, elev, azim)
    norm = np.clip(sub_g / max(vmax, 1e-6), 0.0, 1.0)
    ax.scatter(px, py, c=cm.get_cmap("YlOrRd")(norm), s=s, linewidths=0, rasterized=True)
    set_zoom_limits(ax, he_xyz, center, half, elev, azim)
    ax.set_aspect("equal")
    ax.axis("off")
    mean_g = float(sub_g.mean()) if sub_g.size else 0.0
    ax.set_title(f"{title}\nROI mean gap={mean_g:.1f} mm", fontsize=9, fontweight="bold")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--sequence", default="")
    p.add_argument("--cg-name", default="")
    p.add_argument("--out-dir", default=str(GC2026_ROOT / "output/ft_val565_fusion/figures"))
    p.add_argument("--max-points", type=int, default=150000)
    p.add_argument("--elev", type=float, default=18.0)
    p.add_argument("--azim", type=float, default=-68.0)
    args = p.parse_args()

    if args.sequence and args.cg_name:
        seq, cg = args.sequence, args.cg_name
        ft_rec = fu_rec = {}
        delta = 0.0
    else:
        seq, cg, delta, ft_rec, fu_rec = find_worst_frame()
    cg_path, he_path, ft_path, fu_path, sp_path = cg_to_paths(cg, seq)
    enh_name = cg.replace("_CG_", "_ENH_")

    rng = np.random.RandomState(0)
    he_xyz, he_rgb = read_ply_xyz_rgb(str(he_path), max_points=max(args.max_points, 250000), rng=rng)
    cg_xyz, _ = read_ply_xyz_rgb(str(cg_path), max_points=args.max_points, rng=rng)
    ft_xyz, ft_rgb = read_ply_xyz_rgb(str(ft_path), max_points=args.max_points, rng=rng)
    fu_xyz, fu_rgb = read_ply_xyz_rgb(str(fu_path), max_points=args.max_points, rng=rng)
    sp_xyz, sp_rgb = read_ply_xyz_rgb(str(sp_path), max_points=args.max_points, rng=rng)

    he_al = align_xyz(he_xyz, seq)
    ft_al = align_xyz(ft_xyz, seq)
    fu_al = align_xyz(fu_xyz, seq)
    sp_al = align_xyz(sp_xyz, seq)

    err_ft = he_nn_error(he_al, ft_al)
    err_fu = he_nn_error(he_al, fu_al)
    err_sp = he_nn_error(he_al, sp_al)
    gap_fu_ft = err_fu - err_ft  # positive = fusion worse for HE completeness

    center, half, roi_meta = find_he_worse_roi(he_al, gap_fu_ft, cg_xyz)

    ft_cd = float(ft_rec.get("chamfer_distance", 0)) if ft_rec else 0.0
    fu_cd = float(fu_rec.get("chamfer_distance", 0)) if fu_rec else 0.0
    ft_comp = float(ft_rec.get("completeness", 0)) if ft_rec else float(err_ft.mean())
    fu_comp = float(fu_rec.get("completeness", 0)) if fu_rec else float(err_fu.mean())

    fig = plt.figure(figsize=(15, 9), dpi=180)
    fig.suptitle(
        f"Worst frame: {seq} {enh_name}\n"
        f"CD ft={ft_cd:.2f} mm  fusion={fu_cd:.2f} mm  delta={delta:+.2f} mm | "
        f"completeness ft={ft_comp:.2f}  fusion={fu_comp:.2f} mm",
        fontsize=11,
        y=0.98,
    )

    ax1 = fig.add_subplot(2, 4, 1)
    ax2 = fig.add_subplot(2, 4, 2)
    ax3 = fig.add_subplot(2, 4, 3)
    ax4 = fig.add_subplot(2, 4, 4)
    draw_he_gap_overview(ax1, he_al, he_rgb, err_ft, center, half, args.elev, args.azim, "HE err -> ft density", vmax=40, s=0.3)
    draw_he_gap_overview(ax2, he_al, he_rgb, err_fu, center, half, args.elev, args.azim, "HE err -> fusion", vmax=40, s=0.3)
    draw_he_gap_overview(ax3, he_al, he_rgb, gap_fu_ft, center, half, args.elev, args.azim, "Completeness gap (fusion-ft)", vmax=15, s=0.35)
    px, py = project_points(he_al, args.elev, args.azim)
    ax4.scatter(px, py, c=np.clip(he_rgb, 0, 1), s=0.25, linewidths=0, rasterized=True)
    ax4.set_aspect("equal")
    ax4.axis("off")
    ax4.set_title("HE reference (RGB)", fontsize=8)

    ax5 = fig.add_subplot(2, 4, 5)
    ax6 = fig.add_subplot(2, 4, 6)
    ax7 = fig.add_subplot(2, 4, 7)
    ax8 = fig.add_subplot(2, 4, 8)
    draw_rgb_zoom(ax5, ft_al, ft_rgb, center, half, args.elev, args.azim, f"ROI ft ({ft_xyz.shape[0]:,} pts)", s=3.2)
    draw_rgb_zoom(ax6, fu_al, fu_rgb, center, half, args.elev, args.azim, f"ROI fusion ({fu_xyz.shape[0]:,} pts)", s=3.2)
    draw_rgb_zoom(ax7, sp_al, sp_rgb, center, half, args.elev, args.azim, f"ROI SuperPC ({sp_xyz.shape[0]:,} pts)", s=3.2)
    draw_he_gap_zoom(ax8, he_al, gap_fu_ft, center, half, args.elev, args.azim, "ROI: where fusion loses", vmax=15.0)

    ax_txt = fig.add_axes([0.02, 0.02, 0.96, 0.12])
    ax_txt.axis("off")
    txt = (
        "Diagnosis (preset fill=0.6, r_in=25mm): SuperPC fill replaces ft geometry; "
        f"fusion has {fu_xyz.shape[0]:,} pts vs ft {ft_xyz.shape[0]:,} (fusion ~ SuperPC). "
        f"Completeness gap ROI mean={roi_meta.get('mean_gap_mm', 0):.1f} mm. "
        "New presets: fill 0.2-0.35, r_in 12-18mm (region_hybrid_*_rin15/18/12)."
    )
    ax_txt.text(0.5, 0.5, txt, ha="center", va="center", fontsize=9, wrap=True)

    cbar_ax = fig.add_axes([0.92, 0.58, 0.015, 0.30])
    sm = cm.ScalarMappable(cmap="YlOrRd", norm=plt.Normalize(0, 15))
    fig.colorbar(sm, cax=cbar_ax).set_label("completeness gap (mm)", fontsize=8)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    tag = enh_name.replace(".ply", "")
    out_png = out_dir / f"ft_vs_fusion_gap_{seq}_{tag}.png"
    out_json = out_dir / f"ft_vs_fusion_gap_{seq}_{tag}.json"
    fig.savefig(out_png, bbox_inches="tight", facecolor="white")
    plt.close(fig)

    meta = {
        "sequence": seq,
        "cg_name": cg,
        "enh_name": enh_name,
        "delta_chamfer_mm": delta,
        "ft_chamfer_mm": ft_cd,
        "fusion_chamfer_mm": fu_cd,
        "ft_completeness_mm": ft_comp,
        "fusion_completeness_mm": fu_comp,
        "ft_n_points": int(ft_xyz.shape[0]),
        "fusion_n_points": int(fu_xyz.shape[0]),
        "superpc_n_points": int(sp_xyz.shape[0]),
        "roi": roi_meta,
        "new_presets": [
            "region_hybrid_pdlts_superpc_snap1_fill0.25_density_rin15",
            "region_hybrid_pdlts_superpc_snap1_fill0.35_density_rin18",
            "region_hybrid_pdlts_superpc_snap1_fill0.2_density_rin12",
        ],
    }
    out_json.write_text(json.dumps(meta, indent=2), encoding="utf-8")
    print(json.dumps({"out_png": str(out_png), "meta": meta}, indent=2))


if __name__ == "__main__":
    main()
