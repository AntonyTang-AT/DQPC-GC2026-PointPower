#!/usr/bin/env python3
"""High-contrast zoom figures for val565 (HE official metric + CG fidelity views)."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
from matplotlib import cm
from matplotlib.patches import Rectangle

SCRIPT_DIR = Path(__file__).resolve().parent
GC2026_ROOT = SCRIPT_DIR.parent
sys.path.insert(0, str(SCRIPT_DIR))

from render_val565_error_heatmap import aligned_point_errors  # noqa: E402
from render_val565_paper_figures import (  # noqa: E402
    FIGURES_DIR,
    load_frame_meta,
    resolve_ply_ext,
    tag_from_pick,
)
from render_val565_qualitative import project_points  # noqa: E402
from render_val565_zoom_utils import (  # noqa: E402
    draw_cg_gap_zoom,
    draw_cg_overlay_zoom,
    draw_err_zoom,
    draw_gap_zoom,
    draw_overview_with_box,
    draw_rgb_zoom,
    find_cg_drift_rois,
    find_contrast_rois,
    point_dist_to_cloud,
    projected_box_rect,
)
from uvg_io import read_ply_xyz_rgb  # noqa: E402

# Cloud tuple: (xyz, rgb, err_to_he_aligned, err_to_cg_same_frame)


def cg_path_for_pick(pick) -> Path:
    return (
        GC2026_ROOT / "data/raw/UVG-CWI-DQPC" / pick.sequence
        / "consumer-grade_capture_system/CG/15fps" / pick.cg_name
    )


def load_clouds(pick, max_points: int) -> dict:
    he_path = (
        GC2026_ROOT / "data/raw/UVG-CWI-DQPC" / pick.sequence
        / "high-end_capture_system/HE/15fps" / pick.he_name
    )
    cg_path = cg_path_for_pick(pick)
    he_xyz, he_rgb = read_ply_xyz_rgb(str(he_path), max_points=max(max_points, 150000))
    cg_xyz, cg_rgb = read_ply_xyz_rgb(str(cg_path), max_points=max(max_points, 150000))
    z = np.zeros(1, dtype=np.float32)
    out = {
        "he": (he_xyz, he_rgb, z, z),
        "cg": (cg_xyz, cg_rgb, z, z),
    }
    for key in ("superpc_blend_cg", "pdlts_density", "pdlts_vh_snap0", "pdlts_raw"):
        ply = resolve_ply_ext(GC2026_ROOT, key, pick)
        xyz, rgb = read_ply_xyz_rgb(str(ply), max_points=max_points, rng=np.random.RandomState(42))
        _, err_he, _, _ = aligned_point_errors(ply, he_path, pick.sequence, max_points, 42)
        err_cg = point_dist_to_cloud(xyz, cg_xyz)
        out[key] = (xyz, rgb, err_he, err_cg)
    return out


def render_zoom_highlight(pick, out_dir: Path, args) -> Path:
    """Per-point distance to HE (official accuracy direction)."""
    c = load_clouds(pick, args.max_points)
    sp_xyz, sp_rgb, sp_he, _ = c["superpc_blend_cg"]
    ref_xyz, ref_rgb, ref_he, _ = c["pdlts_density"]
    he_xyz, he_rgb, _, _ = c["he"]

    rois = find_contrast_rois(sp_xyz, sp_he, ref_xyz, ref_he, he_xyz, n_rois=2)
    if len(rois) < 2:
        rois = find_contrast_rois(sp_xyz, sp_he, ref_xyz, ref_he, he_xyz, n_rois=2, min_sp_err=10.0)

    n = max(len(rois), 1)
    fig, axes = plt.subplots(n, 6, figsize=(19, 4.5 * n), dpi=args.dpi)
    if n == 1:
        axes = np.array([axes])
    fig.subplots_adjust(wspace=0.05, hspace=0.25, left=0.01, right=0.90, top=0.86, bottom=0.03)
    fig.suptitle(
        f"vs HE (aligned, official metric) — {pick.sequence}\n"
        f"CD: SuperPC {pick.chamfer['superpc_blend_cg']:.1f} | density {pick.chamfer.get('pdlts_density', 0):.1f} mm",
        fontsize=13,
        fontweight="bold",
    )

    for ri in range(n):
        center, half, meta = rois[ri] if ri < len(rois) else rois[0]
        label = chr(ord("A") + ri)
        row = axes[ri]
        draw_overview_with_box(row[0], he_xyz, he_rgb, center, half, args.elev, args.azim,
                               f"Overview ROI {label}\nΔ→HE={meta.get('mean_gap_mm', 0):.0f}mm", label=label, s=0.05)
        draw_rgb_zoom(row[1], sp_xyz, sp_rgb, center, half, args.elev, args.azim, "SuperPC", s=4.0)
        draw_err_zoom(row[2], sp_xyz, sp_he, center, half, args.elev, args.azim, "SuperPC → HE", args.zoom_vmax, s=4.5)
        draw_err_zoom(row[3], ref_xyz, ref_he, center, half, args.elev, args.azim, "density → HE", args.zoom_vmax, s=4.5)
        draw_gap_zoom(row[4], sp_xyz, sp_he, ref_xyz, ref_he, center, half, args.elev, args.azim,
                      "Excess →HE", args.gap_vmax, s=4.5)
        draw_rgb_zoom(row[5], he_xyz, he_rgb, center, half, args.elev, args.azim, "HE ref", s=3.5)

    for cax, cmap, vmax, lbl in [
        ([0.905, 0.12, 0.014, 0.70], "turbo", args.zoom_vmax, "→ HE (mm)"),
        ([0.925, 0.12, 0.014, 0.70], "YlOrRd", args.gap_vmax, "SP−PD (mm)"),
    ]:
        ax = fig.add_axes(cax)
        fig.colorbar(cm.ScalarMappable(cmap=cmap, norm=plt.Normalize(0, vmax)), cax=ax).set_label(lbl, fontsize=9)

    out_png = out_dir / f"zoom_highlight_he_{tag_from_pick(pick)}.png"
    fig.savefig(out_png, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    return out_png


def render_zoom_cg(pick, out_dir: Path, args) -> Path:
    """Per-point distance to input CG (enhancement fidelity / 保真度)."""
    c = load_clouds(pick, args.max_points)
    sp_xyz, sp_rgb, _, sp_cg = c["superpc_blend_cg"]
    ref_xyz, ref_rgb, _, ref_cg = c["pdlts_density"]
    cg_xyz, cg_rgb, _, _ = c["cg"]

    rois = find_cg_drift_rois(sp_xyz, sp_cg, ref_xyz, ref_cg, cg_xyz, n_rois=2)
    cg_vmax = float(getattr(args, "cg_vmax", 20.0))
    cg_gap_vmax = float(getattr(args, "cg_gap_vmax", 12.0))

    n = max(len(rois), 1)
    fig, axes = plt.subplots(n, 6, figsize=(19, 4.5 * n), dpi=args.dpi)
    if n == 1:
        axes = np.array([axes])
    fig.subplots_adjust(wspace=0.05, hspace=0.25, left=0.01, right=0.90, top=0.86, bottom=0.03)
    fig.suptitle(
        f"vs input CG (same frame, fidelity) — {pick.sequence}\n"
        f"Gray=CG input | Color=ENH distance to nearest CG (SuperPC drift / extra points)",
        fontsize=12,
        fontweight="bold",
    )

    for ri in range(n):
        center, half, meta = rois[ri] if ri < len(rois) else rois[0]
        label = chr(ord("A") + ri)
        row = axes[ri]
        draw_overview_with_box(row[0], cg_xyz, cg_rgb, center, half, args.elev, args.azim,
                               f"CG overview ROI {label}\nΔ→CG={meta.get('mean_cg_gap_mm', 0):.0f}mm",
                               label=label, s=0.05)
        draw_cg_overlay_zoom(row[1], sp_xyz, sp_cg, cg_xyz, cg_rgb, center, half, args.elev, args.azim,
                             "SuperPC on CG", cg_vmax, s_enh=4.5, s_cg=2.0)
        draw_err_zoom(row[2], sp_xyz, sp_cg, center, half, args.elev, args.azim,
                      "SuperPC → CG", cg_vmax, s=4.5)
        draw_err_zoom(row[3], ref_xyz, ref_cg, center, half, args.elev, args.azim,
                      "density → CG", cg_vmax, s=4.5)
        draw_cg_gap_zoom(row[4], sp_xyz, sp_cg, ref_xyz, ref_cg, center, half, args.elev, args.azim,
                         "Excess →CG (SP−PD)", cg_gap_vmax, s=4.5)
        draw_rgb_zoom(row[5], cg_xyz, cg_rgb, center, half, args.elev, args.azim, "CG (input)", s=3.0)

    ax1 = fig.add_axes([0.905, 0.12, 0.014, 0.70])
    fig.colorbar(cm.ScalarMappable(cmap="turbo", norm=plt.Normalize(0, cg_vmax)), cax=ax1).set_label("→ CG (mm)", fontsize=9)
    ax2 = fig.add_axes([0.925, 0.12, 0.014, 0.70])
    fig.colorbar(cm.ScalarMappable(cmap="YlOrRd", norm=plt.Normalize(0, cg_gap_vmax)), cax=ax2).set_label("SP−PD (mm)", fontsize=9)

    out_png = out_dir / f"zoom_highlight_cg_{tag_from_pick(pick)}.png"
    fig.savefig(out_png, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    (out_dir / f"zoom_highlight_cg_{tag_from_pick(pick)}.json").write_text(
        json.dumps({"reference": "cg", "rois": [{"center": c.tolist(), "half": h.tolist(), **m} for c, h, m in rois]}, indent=2),
        encoding="utf-8",
    )
    return out_png


def render_dual_reference(pick, out_dir: Path, args) -> Path:
    """Same ROI: top row vs HE, bottom row vs CG — for one-slide comparison."""
    c = load_clouds(pick, args.max_points)
    sp_xyz, sp_rgb, sp_he, sp_cg = c["superpc_blend_cg"]
    ref_xyz, _, ref_he, ref_cg = c["pdlts_density"]
    cg_xyz, cg_rgb, _, _ = c["cg"]
    he_xyz, he_rgb, _, _ = c["he"]

    rois_he = find_contrast_rois(sp_xyz, sp_he, ref_xyz, ref_he, he_xyz, n_rois=1)
    rois_cg = find_cg_drift_rois(sp_xyz, sp_cg, ref_xyz, ref_cg, cg_xyz, n_rois=1)
    center_he, half_he = (rois_he[0][0], rois_he[0][1]) if rois_he else (he_xyz.mean(0), np.array([22., 22., 35.]))
    center_cg, half_cg = (rois_cg[0][0], rois_cg[0][1]) if rois_cg else (cg_xyz.mean(0), np.array([22., 22., 35.]))

    fig = plt.figure(figsize=(14, 11), dpi=args.dpi)
    gs = fig.add_gridspec(2, 4, hspace=0.28, wspace=0.06, height_ratios=[1, 1])
    fig.suptitle(
        f"Dual reference — {pick.enh_name}\n"
        f"Top: distance to HE (official)  |  Bottom: distance to CG (input fidelity)",
        fontsize=13,
        fontweight="bold",
        y=0.98,
    )
    cg_vmax = float(getattr(args, "cg_vmax", 20.0))

    # Row HE
    draw_overview_with_box(fig.add_subplot(gs[0, 0]), he_xyz, he_rgb, center_he, half_he, args.elev, args.azim,
                           "ROI (HE criterion)", "H", s=0.06)
    draw_err_zoom(fig.add_subplot(gs[0, 1]), sp_xyz, sp_he, center_he, half_he, args.elev, args.azim,
                  "SuperPC → HE", args.zoom_vmax, s=5.0)
    draw_err_zoom(fig.add_subplot(gs[0, 2]), ref_xyz, ref_he, center_he, half_he, args.elev, args.azim,
                  "density → HE", args.zoom_vmax, s=5.0)
    draw_gap_zoom(fig.add_subplot(gs[0, 3]), sp_xyz, sp_he, ref_xyz, ref_he, center_he, half_he, args.elev, args.azim,
                  "SP−PD →HE", args.gap_vmax, s=5.0)

    # Row CG
    draw_overview_with_box(fig.add_subplot(gs[1, 0]), cg_xyz, cg_rgb, center_cg, half_cg, args.elev, args.azim,
                           "ROI (CG drift)", "C", s=0.06)
    draw_cg_overlay_zoom(fig.add_subplot(gs[1, 1]), sp_xyz, sp_cg, cg_xyz, cg_rgb, center_cg, half_cg,
                         args.elev, args.azim, "SuperPC on CG", cg_vmax, s_enh=5.0)
    draw_err_zoom(fig.add_subplot(gs[1, 2]), ref_xyz, ref_cg, center_cg, half_cg, args.elev, args.azim,
                  "density → CG", cg_vmax, s=5.0)
    draw_cg_gap_zoom(fig.add_subplot(gs[1, 3]), sp_xyz, sp_cg, ref_xyz, ref_cg, center_cg, half_cg,
                     args.elev, args.azim, "SP−PD →CG", float(getattr(args, "cg_gap_vmax", 12.0)), s=5.0)

    out_png = out_dir / f"dual_reference_{tag_from_pick(pick)}.png"
    fig.savefig(out_png, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    return out_png


def render_heatmap_zoom(pick, out_dir: Path, args) -> Path:
    c = load_clouds(pick, args.max_points)
    sp_xyz, _, sp_he, sp_cg = c["superpc_blend_cg"]
    ref_xyz, _, ref_he, ref_cg = c["pdlts_density"]
    he_xyz, _, _, _ = c["he"]
    cg_xyz, _, _, _ = c["cg"]
    rois = find_cg_drift_rois(sp_xyz, sp_cg, ref_xyz, ref_cg, cg_xyz, n_rois=1)
    if not rois:
        rois = find_contrast_rois(sp_xyz, sp_he, ref_xyz, ref_he, he_xyz, n_rois=1)
    center, half = rois[0][0], rois[0][1]

    fig, axes = plt.subplots(2, 3, figsize=(14, 10), dpi=args.dpi)
    fig.subplots_adjust(wspace=0.04, hspace=0.22, top=0.88, right=0.86, bottom=0.06)
    fig.suptitle("Heatmap zoom: row1 → HE (official)  |  row2 → CG (input)", fontsize=12, fontweight="bold")

    for j, (title, xyz, err, vmax) in enumerate([
        ("SuperPC", sp_xyz, sp_he, args.zoom_vmax),
        ("PD-LTS raw", c["pdlts_raw"][0], c["pdlts_raw"][2], args.zoom_vmax),
        ("density", ref_xyz, ref_he, args.zoom_vmax),
    ]):
        draw_err_zoom(axes[0, j], xyz, err, center, half, args.elev, args.azim, f"{title} →HE", vmax, s=5.0)

    cg_vmax = float(getattr(args, "cg_vmax", 20.0))
    for j, (title, xyz, err) in enumerate([
        ("SuperPC", sp_xyz, sp_cg),
        ("PD-LTS raw", c["pdlts_raw"][0], c["pdlts_raw"][3]),
        ("density", ref_xyz, ref_cg),
    ]):
        draw_err_zoom(axes[1, j], xyz, err, center, half, args.elev, args.azim, f"{title} →CG", cg_vmax, s=5.0)

    out_png = out_dir / f"heatmap_dual_{tag_from_pick(pick)}.png"
    fig.savefig(out_png, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    return out_png


def render_ablation_zoom(pick, out_dir: Path, args) -> Path:
    c = load_clouds(pick, args.max_points)
    sp_xyz, _, _, sp_cg = c["superpc_blend_cg"]
    ref_xyz, _, _, ref_cg = c["pdlts_density"]
    cg_xyz, cg_rgb, _, _ = c["cg"]
    rois = find_cg_drift_rois(sp_xyz, sp_cg, ref_xyz, ref_cg, cg_xyz, n_rois=1)
    center, half = (rois[0][0], rois[0][1]) if rois else (cg_xyz.mean(0), np.array([22., 22., 35.]))

    panels = [("pdlts_raw", "raw"), ("pdlts_density", "density"), ("pdlts_vh_snap0", "vh")]
    fig = plt.figure(figsize=(14, 9), dpi=args.dpi)
    gs = fig.add_gridspec(2, 3, height_ratios=[1.2, 1.4], hspace=0.22, wspace=0.06)
    cg_vmax = float(getattr(args, "cg_vmax", 20.0))

    draw_overview_with_box(fig.add_subplot(gs[0, :]), cg_xyz, cg_rgb, center, half, args.elev, args.azim,
                           "Ablation zoom — distance to CG (input fidelity)", "★", s=0.06)

    for j, (key, title) in enumerate(panels):
        xyz, rgb, _, err_cg = c[key]
        draw_cg_overlay_zoom(fig.add_subplot(gs[1, j]), xyz, err_cg, cg_xyz, cg_rgb, center, half,
                             args.elev, args.azim, title, cg_vmax, s_enh=5.0)

    fig.suptitle(f"Refine ablation vs CG — {pick.sequence}", fontsize=13, fontweight="bold", y=0.98)
    out_png = out_dir / f"ablation_zoom_cg_{tag_from_pick(pick)}.png"
    fig.savefig(out_png, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    return out_png


def render_side_by_side(pick, out_dir: Path, args) -> Path:
    c = load_clouds(pick, args.max_points)
    sp_xyz, sp_rgb, _, sp_cg = c["superpc_blend_cg"]
    ref_xyz, ref_rgb, _, ref_cg = c["pdlts_density"]
    cg_xyz, cg_rgb, _, _ = c["cg"]
    rois = find_cg_drift_rois(sp_xyz, sp_cg, ref_xyz, ref_cg, cg_xyz, n_rois=2) or [
        (cg_xyz.mean(0), np.array([25., 25., 40.]), {})
    ]

    n = min(2, len(rois))
    fig, axes = plt.subplots(n, 3, figsize=(12, 5 * n), dpi=args.dpi)
    if n == 1:
        axes = axes.reshape(1, -1)
    fig.suptitle("RGB zoom vs input CG (middle= density, right= CG ground truth)", fontsize=12, fontweight="bold")

    for ri in range(n):
        center, half, meta = rois[ri]
        draw_rgb_zoom(axes[ri, 0], sp_xyz, sp_rgb, center, half, args.elev, args.azim,
                      f"SuperPC Δ→CG={meta.get('mean_cg_gap_mm', 0):.0f}mm", s=5.5)
        draw_rgb_zoom(axes[ri, 1], ref_xyz, ref_rgb, center, half, args.elev, args.azim, "density", s=5.5)
        draw_rgb_zoom(axes[ri, 2], cg_xyz, cg_rgb, center, half, args.elev, args.azim, "CG input", s=5.0)

    out_png = out_dir / f"sidebyside_cg_{tag_from_pick(pick)}.png"
    fig.savefig(out_png, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    return out_png


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--out-dir", default=str(FIGURES_DIR))
    p.add_argument("--figures", default="all")
    p.add_argument("--frame-meta", default="")
    p.add_argument("--max-points", type=int, default=120000)
    p.add_argument("--zoom-vmax", type=float, default=35.0)
    p.add_argument("--gap-vmax", type=float, default=28.0)
    p.add_argument("--cg-vmax", type=float, default=20.0)
    p.add_argument("--cg-gap-vmax", type=float, default=12.0)
    p.add_argument("--elev", type=float, default=18.0)
    p.add_argument("--azim", type=float, default=-68.0)
    p.add_argument("--dpi", type=int, default=240)
    args = p.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    meta_path = Path(args.frame_meta) if args.frame_meta else None
    if meta_path is None:
        for candidate in (FIGURES_DIR / "meta.json",):
            if candidate.is_file():
                meta_path = candidate
                break
    pick = load_frame_meta(meta_path)

    fns = {
        "zoom_cg": render_zoom_cg,
        "zoom_he": render_zoom_highlight,
        "dual": render_dual_reference,
        "heatmap_dual": render_heatmap_zoom,
        "ablation_cg": render_ablation_zoom,
        "sidebyside_cg": render_side_by_side,
    }
    default_all = ["zoom_cg", "dual", "heatmap_dual", "ablation_cg", "sidebyside_cg", "zoom_he"]
    names = default_all if args.figures == "all" else [x.strip() for x in args.figures.split(",")]
    results = []
    for name in names:
        if name not in fns:
            raise SystemExit(f"Unknown: {name}. Choose from {list(fns)}")
        print(f"[zoom] {name}...")
        path = fns[name](pick, out_dir, args)
        results.append(str(path))
        print(f"  -> {path}")
    print(json.dumps({"outputs": results}, indent=2))


if __name__ == "__main__":
    main()
