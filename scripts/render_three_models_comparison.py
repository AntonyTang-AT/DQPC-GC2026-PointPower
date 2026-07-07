#!/usr/bin/env python3
"""CG + SuperPC + PD-LTS + Ours + HE — compare5 layout + CCW90 + legacy HE viz."""
from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import matplotlib.pyplot as plt
import numpy as np
from matplotlib.patches import Rectangle
from scipy.spatial import cKDTree

SCRIPT_DIR = Path(__file__).resolve().parent
GC2026_ROOT = SCRIPT_DIR.parent
sys.path.insert(0, str(SCRIPT_DIR))

from evaluate_gc_baseline_metrics import apply_transform, eval_aligned_pair, load_align_matrix  # noqa: E402
from render_val565_qualitative import mask_box, project_points  # noqa: E402
from render_val565_zoom_utils import scene_bounds  # noqa: E402
from uvg_io import read_ply_xyz_rgb  # noqa: E402

THRESHOLDS = (10.0, 20.0, 30.0, 50.0)

THREE_MODELS: List[Tuple[str, str, Optional[Path]]] = [
    ("superpc", "SuperPC", None),
    ("pdlts_frozen", "PD-LTS", GC2026_ROOT / "output/enh_refine_val565_selection/vh_snap0"),
    ("fusion_ft", "Ours", GC2026_ROOT / "output/ft_val565_fusion/holefill_adaptive_frame_gate_v2"),
]

SUPERPC_FILTER_GEOM = GC2026_ROOT / "output/meeting_delivery_viz/superpc_filter_cg_geom"
SUPERPC_CACHE = GC2026_ROOT / "output/meeting_delivery_viz/superpc_filter_snap1.0"

DEFAULT_FRAMES: List[Tuple[str, str, str]] = [
    ("TrumanShow", "TrumanShow_UVG-CWI-DQPC_CG_15_0_170_0072.ply", "ts0072"),
    ("TrumanShow", "TrumanShow_UVG-CWI-DQPC_CG_15_0_170_0155.ply", "ts0155"),
    ("VictoryHeart", "VictoryHeart_UVG-CWI-DQPC_CG_15_0_196_0041.ply", "vh0041"),
    ("VictoryHeart", "VictoryHeart_UVG-CWI-DQPC_CG_15_0_196_0105.ply", "vh0105"),
    ("VirtualLife", "VirtualLife_UVG-CWI-DQPC_CG_15_0_195_0063.ply", "vl0063"),
    ("VirtualLife", "VirtualLife_UVG-CWI-DQPC_CG_15_0_195_0148.ply", "vl0148"),
]

FULL_S = 0.10
ZOOM_S = 2.4
HE_ZOOM_S = 1.35
COL_W = 2.80
FIG_H = 8.5
DPI = 200
ZOOM_RECT_SCALE = 1.12
ZOOM_VIEW_PAD = 0.035


def align_xyz(xyz: np.ndarray, sequence: str) -> np.ndarray:
    return apply_transform(xyz.astype(np.float64), load_align_matrix(sequence)).astype(np.float32)


def rot_ccw90(px: np.ndarray, py: np.ndarray) -> Tuple[np.ndarray, np.ndarray]:
    return (-py).astype(np.float64), px.astype(np.float64)


def view_project(xyz: np.ndarray, elev: float, azim: float) -> Tuple[np.ndarray, np.ndarray]:
    px, py = project_points(xyz, elev, azim)
    return rot_ccw90(px, py)


def cg_point_error(cg_xyz: np.ndarray, he_xyz: np.ndarray) -> np.ndarray:
    tree = cKDTree(he_xyz.astype(np.float64))
    dist, _ = tree.query(cg_xyz.astype(np.float64), k=1, workers=-1)
    return dist.astype(np.float32)


def find_roi(cg_xyz: np.ndarray, he_xyz: np.ndarray, cg_err: np.ndarray) -> Tuple[np.ndarray, np.ndarray]:
    cap = float(np.percentile(cg_err, 92))
    valid = cg_err <= max(cap, 25.0)
    score_pts = np.where(valid, cg_err, 0.0)
    mins, maxs = scene_bounds(cg_xyz[valid] if np.any(valid) else cg_xyz)
    span = maxs - mins
    half = np.maximum(span * np.array([0.042, 0.042, 0.065]), np.array([12.0, 12.0, 24.0]))
    best_score, best_center = -1.0, mins + 0.5 * span
    for ux in np.linspace(0.30, 0.70, 7):
        for uy in np.linspace(0.25, 0.75, 8):
            for uz in (0.45, 0.55):
                center = mins + span * np.array([ux, uy, uz])
                m = mask_box(cg_xyz, center, half) & valid
                if int(m.sum()) < 100:
                    continue
                sc = float(np.mean(score_pts[m]))
                ce = float(np.mean(cg_err[m]))
                if sc > best_score and 10.0 < ce < cap:
                    best_score, best_center = sc, center.copy()
    return best_center, half


def he_correspondence_mask(
    he_met: np.ndarray,
    cg_met: np.ndarray,
    center: np.ndarray,
    half: np.ndarray,
) -> np.ndarray:
    cg_m = mask_box(cg_met, center, half)
    roi = cg_met[cg_m]
    if roi.shape[0] < 20:
        return np.zeros(he_met.shape[0], dtype=bool)
    tree_he = cKDTree(he_met.astype(np.float64))
    dist_cg_to_he, idx = tree_he.query(roi.astype(np.float64), k=1, workers=-1)
    he_mask = np.zeros(he_met.shape[0], dtype=bool)
    he_mask[idx] = True
    tree_roi = cKDTree(roi.astype(np.float64))
    dist_he_to_roi, _ = tree_roi.query(he_met.astype(np.float64), k=1, workers=-1)
    thr = float(np.clip(np.percentile(dist_cg_to_he, 90), 40.0, 130.0))
    he_mask |= dist_he_to_roi <= thr
    if int(he_mask.sum()) < 50:
        thr = float(np.clip(np.percentile(dist_cg_to_he, 96), 50.0, 160.0))
        he_mask = dist_he_to_roi <= thr
        he_mask[idx] = True
    return he_mask


def projected_box_2d(center, half, elev, azim) -> Tuple[float, float, float, float]:
    corners = np.array(
        [[center[0] + sx * half[0], center[1] + sy * half[1], center[2] + sz * half[2]]
         for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)]
    )
    px, py = view_project(corners, elev, azim)
    return float(px.min()), float(px.max()), float(py.min()), float(py.max())


def rel_rect_from_abs(xlim, ylim, bx0, bx1, by0, by1) -> Tuple[float, float, float, float]:
    xl0, xl1 = xlim
    yl0, yl1 = ylim
    w, h = xl1 - xl0, yl1 - yl0
    return (bx0 - xl0) / w, (by0 - yl0) / h, (bx1 - bx0) / w, (by1 - by0) / h


def abs_rect_from_rel(xlim, ylim, rel) -> Tuple[float, float, float, float]:
    xl0, xl1 = xlim
    yl0, yl1 = ylim
    w, h = xl1 - xl0, yl1 - yl0
    rx, ry, rw, rh = rel
    ax0 = xl0 + rx * w
    ay0 = yl0 + ry * h
    return ax0, ax0 + rw * w, ay0, ay0 + rh * h


def expand_rect(abs_rect: Tuple[float, float, float, float], scale: float = 1.12) -> Tuple[float, float, float, float]:
    x0, x1, y0, y1 = abs_rect
    cx, cy = (x0 + x1) * 0.5, (y0 + y1) * 0.5
    w, h = max(x1 - x0, 1e-4) * scale, max(y1 - y0, 1e-4) * scale
    return cx - w * 0.5, cx + w * 0.5, cy - h * 0.5, cy + h * 0.5


def rect_mask_2d(px, py, abs_rect, *, scale: float = ZOOM_RECT_SCALE) -> np.ndarray:
    x0, x1, y0, y1 = expand_rect(abs_rect, scale=scale)
    return (px >= x0) & (px <= x1) & (py >= y0) & (py <= y1)


def zoom_view_limits(abs_rect) -> Tuple[Tuple[float, float], Tuple[float, float]]:
    x0, x1, y0, y1 = expand_rect(abs_rect, scale=ZOOM_RECT_SCALE)
    cx, cy = (x0 + x1) * 0.5, (y0 + y1) * 0.5
    span = max(x1 - x0, y1 - y0, 1e-4) * (1.0 + 2.0 * ZOOM_VIEW_PAD)
    half = span * 0.5
    return (cx - half, cx + half), (cy - half, cy + half)


def he_zoom_selection(px_he, py_he, he_corr, abs_rect) -> np.ndarray:
    return rect_mask_2d(px_he, py_he, abs_rect, scale=ZOOM_RECT_SCALE)


def cg_full_limits(cg_xyz: np.ndarray, elev: float, azim: float, pad: float = 0.035):
    px, py = view_project(cg_xyz, elev, azim)
    x0, x1 = float(np.percentile(px, 2)), float(np.percentile(px, 98))
    y0, y1 = float(np.percentile(py, 2)), float(np.percentile(py, 98))
    dx = max(x1 - x0, 1e-3) * pad
    dy = max(y1 - y0, 1e-3) * pad
    return (x0 - dx, x1 + dx), (y0 - dy, y1 + dy)


def view_set_zoom_limits(ax, xyz, center, half, elev, azim, pad: float = 0.08):
    m = mask_box(xyz, center, half)
    px, py = view_project(xyz[m] if np.any(m) else xyz, elev, azim)
    if px.size == 0:
        return
    dx = (px.max() - px.min()) * pad + 1e-3
    dy = (py.max() - py.min()) * pad + 1e-3
    ax.set_xlim(px.min() - dx, px.max() + dx)
    ax.set_ylim(py.min() - dy, py.max() + dy)


def draw_roi_rect(ax, xlim, ylim, rel_rect):
    bx0, bx1, by0, by1 = abs_rect_from_rel(xlim, ylim, rel_rect)
    ax.add_patch(Rectangle((bx0, by0), bx1 - bx0, by1 - by0, fill=False, edgecolor="#e53935", linewidth=1.6))


def draw_full_shared(ax, px, py, rgb, xlim, ylim, rel_rect, s=FULL_S):
    ax.scatter(px, py, c=np.clip(rgb, 0, 1), s=s, linewidths=0, rasterized=True)
    ax.set_xlim(xlim)
    ax.set_ylim(ylim)
    draw_roi_rect(ax, xlim, ylim, rel_rect)
    ax.set_aspect("equal")


def draw_full_model(ax, xyz, rgb, elev, azim, xlim, ylim, rel_rect, s=FULL_S):
    px, py = view_project(xyz, elev, azim)
    ax.scatter(px, py, c=np.clip(rgb, 0, 1), s=s, linewidths=0, rasterized=True)
    ax.set_xlim(xlim)
    ax.set_ylim(ylim)
    draw_roi_rect(ax, xlim, ylim, rel_rect)
    ax.set_aspect("equal")


def draw_full_plain(ax, px, py, rgb, xlim, ylim, s=FULL_S):
    ax.scatter(px, py, c=np.clip(rgb, 0, 1), s=s, linewidths=0, rasterized=True)
    ax.set_xlim(xlim)
    ax.set_ylim(ylim)
    ax.set_aspect("equal")


def style_axis(ax) -> None:
    ax.set_aspect("equal")
    ax.set_xticks([])
    ax.set_yticks([])
    ax.axis("off")


def style_column_axes(ax_full, ax_zoom) -> None:
    style_axis(ax_full)
    style_axis(ax_zoom)


def cd_mm(ply: Path, he_path: Path, sequence: str) -> Optional[float]:
    if not ply.is_file():
        return None
    try:
        return float(eval_aligned_pair(str(ply), str(he_path), sequence, THRESHOLDS, 0, 0)["chamfer_distance"])
    except Exception:
        return None


def frame_id(cg_name: str) -> str:
    m = re.search(r"_(\d+)\.ply$", cg_name)
    return m.group(1) if m else cg_name[:12]


def ensure_superpc_ply(cg_path: Path, sequence: str, enh: str) -> Path:
    out_ply = SUPERPC_CACHE / sequence / enh
    meta_path = out_ply.with_suffix(".meta.json")
    if out_ply.is_file() and meta_path.is_file():
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        if meta.get("viz_geometry_source") == "superpc_filter_cg":
            return out_ply
        out_ply.unlink(missing_ok=True)
        meta_path.unlink(missing_ok=True)

    geom_ply = SUPERPC_FILTER_GEOM / sequence / enh
    if not geom_ply.is_file():
        raise FileNotFoundError(f"missing SuperPC filter_cg geometry: {geom_ply}")

    from enh_refine_config import resolve_preset  # noqa: WPS433
    from enh_refine_pipeline import apply_refine_stages  # noqa: WPS433
    from uvg_io import write_ply_xyz_rgb  # noqa: WPS433

    rng = np.random.RandomState(0)
    cg_xyz, cg_rgb = read_ply_xyz_rgb(str(cg_path), max_points=180000, rng=rng)
    cfg = resolve_preset("superpc_filter_snap1.0")
    out_xyz, out_rgb, meta = apply_refine_stages(
        cg_xyz, cg_rgb, cfg, cg_path=str(cg_path), geometry_dir=str(SUPERPC_FILTER_GEOM),
    )
    meta["viz_geometry_source"] = "superpc_filter_cg"
    out_ply.parent.mkdir(parents=True, exist_ok=True)
    write_ply_xyz_rgb(str(out_ply), out_xyz, out_rgb)
    meta_path.write_text(json.dumps(meta, indent=2), encoding="utf-8")
    return out_ply


def load_metrics_cd() -> Dict[str, Dict[str, float]]:
    mapping = {
        "superpc": "metrics/01_superpc_best_val565.csv",
        "pdlts_frozen": "metrics/02_pdlts_frozen_best_val565.csv",
        "fusion_ft": "metrics/05_fusion_finetune_pdlts_best_val565.csv",
    }
    out: Dict[str, Dict[str, float]] = {}
    for key, rel in mapping.items():
        path = GC2026_ROOT / "docs/meeting_delivery" / rel
        if not path.is_file():
            continue
        per_frame = [r for r in csv.DictReader(open(path, encoding="utf-8")) if r.get("test_file")]
        if per_frame:
            out[key] = {r["test_file"]: float(r["chamfer_distance"]) for r in per_frame}
    return out


def render_frame(
    sequence: str,
    cg_name: str,
    slug: str,
    out_dir: Path,
    *,
    elev: float,
    azim: float,
    max_points: int,
    metrics: Dict[str, Dict[str, float]],
) -> Optional[Path]:
    enh = cg_name.replace("_CG_", "_ENH_")
    he_name = enh.replace("_ENH_", "_HE_")
    raw = GC2026_ROOT / "data/raw/UVG-CWI-DQPC" / sequence
    cg_path = raw / "consumer-grade_capture_system/CG/15fps" / cg_name
    he_path = raw / "high-end_capture_system/HE/15fps" / he_name
    if not cg_path.is_file() or not he_path.is_file():
        return None

    try:
        superpc_ply = ensure_superpc_ply(cg_path, sequence, enh)
    except FileNotFoundError as e:
        print(f"skip {slug}: {e}", file=sys.stderr)
        return None

    model_paths: Dict[str, Path] = {
        "superpc": superpc_ply,
        "pdlts_frozen": THREE_MODELS[1][2] / sequence / enh,  # type: ignore[operator]
        "fusion_ft": THREE_MODELS[2][2] / sequence / enh,  # type: ignore[operator]
    }
    missing = [k for k, p in model_paths.items() if not p.is_file()]
    if missing:
        print(f"skip {slug}: missing {missing}", file=sys.stderr)
        return None

    rng = np.random.RandomState(0)
    cg_xyz, cg_rgb = read_ply_xyz_rgb(str(cg_path), max_points=max_points, rng=rng)
    he_xyz, he_rgb = read_ply_xyz_rgb(str(he_path), max_points=max(max_points, 200000), rng=rng)
    cg_al = align_xyz(cg_xyz, sequence)
    he_al = he_xyz.astype(np.float32)  # gc_baseline：HE 不乘对齐矩阵

    cg_err = cg_point_error(cg_al, he_al)
    center, half = find_roi(cg_al, he_al, cg_err)
    he_corr = he_correspondence_mask(he_al, cg_al, center, half)

    px_cg, py_cg = view_project(cg_al, elev, azim)
    px_he, py_he = view_project(he_al, elev, azim)
    full_xlim, full_ylim = cg_full_limits(cg_al, elev, azim)

    bx0, bx1, by0, by1 = projected_box_2d(center, half, elev, azim)
    rel_rect = rel_rect_from_abs(full_xlim, full_ylim, bx0, bx1, by0, by1)
    rel_rect = (
        float(np.clip(rel_rect[0], 0.0, 0.92)),
        float(np.clip(rel_rect[1], 0.0, 0.92)),
        float(np.clip(rel_rect[2], 0.03, 0.22)),
        float(np.clip(rel_rect[3], 0.03, 0.22)),
    )
    abs_rect = abs_rect_from_rel(full_xlim, full_ylim, rel_rect)
    zoom_xlim, zoom_ylim = zoom_view_limits(abs_rect)
    he_zoom_m = he_zoom_selection(px_he, py_he, he_corr, abs_rect)

    cds: Dict[str, Optional[float]] = {"cg": cd_mm(cg_path, he_path, sequence)}
    clouds: Dict[str, Tuple[np.ndarray, np.ndarray]] = {
        "cg": (cg_al, cg_rgb),
        "he": (he_al, he_rgb),
    }
    for key, table in (
        ("superpc", metrics.get("superpc", {})),
        ("pdlts_frozen", metrics.get("pdlts_frozen", {})),
        ("fusion_ft", metrics.get("fusion_ft", {})),
    ):
        cds[key] = table.get(enh)

    for key, ply in model_paths.items():
        xyz, rgb = read_ply_xyz_rgb(str(ply), max_points=max_points, rng=rng)
        clouds[key] = (align_xyz(xyz, sequence), rgb)
        if cds.get(key) is None:
            cds[key] = cd_mm(ply, he_path, sequence)

    panels: List[Tuple[str, str]] = [("cg", "CG")]
    panels += [(k, lbl) for k, lbl, _ in THREE_MODELS]
    panels.append(("he", "HE"))
    ncols = len(panels)

    fig = plt.figure(figsize=(COL_W * ncols, FIG_H), dpi=DPI)
    outer = fig.add_gridspec(1, ncols, wspace=0.14)

    for j, (key, label) in enumerate(panels):
        xyz, rgb = clouds[key]
        cd = cds.get(key)

        if key == "he":
            col = outer[j].subgridspec(1, 1)
            ax_full = fig.add_subplot(col[0])
            draw_full_plain(ax_full, px_he, py_he, he_rgb, full_xlim, full_ylim, s=FULL_S)
            ax_full.set_title(label, fontsize=11, pad=5, fontweight="semibold")
            style_axis(ax_full)
            continue

        col = outer[j].subgridspec(2, 1, height_ratios=[1.0, 1.08], hspace=0.03)
        ax_full = fig.add_subplot(col[0])
        ax_zoom = fig.add_subplot(col[1])

        if key == "cg":
            draw_full_shared(ax_full, px_cg, py_cg, cg_rgb, full_xlim, full_ylim, rel_rect)
        else:
            draw_full_model(ax_full, xyz, rgb, elev, azim, full_xlim, full_ylim, rel_rect)

        ax_full.set_title(label, fontsize=11, pad=5, fontweight="semibold")

        zoom_m = mask_box(xyz, center, half)
        px_z, py_z = view_project(xyz[zoom_m], elev, azim)
        ax_zoom.scatter(px_z, py_z, c=np.clip(rgb[zoom_m], 0, 1), s=ZOOM_S, linewidths=0, rasterized=True)
        view_set_zoom_limits(ax_zoom, xyz, center, half, elev, azim)

        if cd is not None:
            ax_zoom.text(
                0.5, -0.06, f"CD {cd:.1f} mm",
                transform=ax_zoom.transAxes, ha="center", va="top", fontsize=9, color="#444444",
            )

        style_column_axes(ax_full, ax_zoom)

    fig.text(0.5, 0.012, f"{sequence}  #{frame_id(cg_name)}", ha="center", fontsize=9, color="#555555")

    out_png = out_dir / f"compare3_cols_{slug}.png"
    fig.savefig(out_png, bbox_inches="tight", facecolor="white", pad_inches=0.06)
    plt.close(fig)

    out_png.with_suffix(".json").write_text(
        json.dumps(
            {
                "sequence": sequence,
                "view_rotated_ccw90": True,
                "he_viz": "full_only_no_zoom",
                "alignment": "CG+models: align_cg(); HE: raw (gc_baseline eval convention)",
                "elev_azim": [elev, azim],
                "scatter_s": {"full": FULL_S, "zoom": ZOOM_S, "he_zoom": HE_ZOOM_S},
                "figsize_in": [COL_W * ncols, FIG_H],
                "chamfer_mm": {k: v for k, v in cds.items() if v},
                "he_zoom_points": int(he_zoom_m.sum()),
            },
            indent=2,
        ),
        encoding="utf-8",
    )
    return out_png


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--out-dir", default=str(GC2026_ROOT / "docs/meeting_delivery/figures"))
    p.add_argument("--elev", type=float, default=16.0)
    p.add_argument("--azim", type=float, default=-72.0)
    p.add_argument("--max-points", type=int, default=160000)
    args = p.parse_args()

    out_dir = Path(args.out_dir)
    metrics = load_metrics_cd()
    results = []
    for sequence, cg_name, slug in DEFAULT_FRAMES:
        path = render_frame(
            sequence, cg_name, slug, out_dir,
            elev=args.elev, azim=args.azim,
            max_points=args.max_points, metrics=metrics,
        )
        if path:
            results.append(str(path))
            print(path)

    for old in out_dir.glob("compare3_lr_*.png"):
        old.unlink(missing_ok=True)
        j = old.with_suffix(".json")
        if j.is_file():
            j.unlink()

    manifest = out_dir / "compare3_manifest.json"
    manifest.write_text(
        json.dumps({"figures": results, "view_rotated_ccw90": True}, indent=2),
        encoding="utf-8",
    )
    print(json.dumps({"count": len(results), "manifest": str(manifest)}, indent=2))


if __name__ == "__main__":
    main()
