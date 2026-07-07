#!/usr/bin/env python3
"""Five canonical models + CG/HE at the same ROI (minimal English labels)."""
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
from render_val565_zoom_utils import scene_bounds, set_zoom_limits  # noqa: E402
from uvg_io import read_ply_xyz_rgb  # noqa: E402

THRESHOLDS = (10.0, 20.0, 30.0, 50.0)

# Canonical five lines (per-frame PLY roots on val565)
FIVE_MODELS: List[Tuple[str, str, Path]] = [
    ("superpc", "SuperPC", GC2026_ROOT / "output/submission_candidate"),
    ("pdlts", "PD-LTS", GC2026_ROOT / "output/enh_refine_val565_selection/vh_snap0"),
    ("pdlts_ft", "PD-LTS-FT", GC2026_ROOT / "output/pdlts_finetune_uvg/val565_refine/pdlts_light_snap1_fill0.6_density"),
    ("hybrid", "Hybrid", GC2026_ROOT / "output/enh_refine_val565_selection/region_hybrid_pdlts_superpc_snap1_fill0.6_density"),
    ("ours", "Ours", GC2026_ROOT / "output/ft_val565_fusion/holefill_adaptive_frame_gate_v2"),
]

DEFAULT_FRAMES: List[Tuple[str, str, str]] = [
    ("TrumanShow", "TrumanShow_UVG-CWI-DQPC_CG_15_0_170_0072.ply", "ts0072"),
    ("TrumanShow", "TrumanShow_UVG-CWI-DQPC_CG_15_0_170_0155.ply", "ts0155"),
    ("VictoryHeart", "VictoryHeart_UVG-CWI-DQPC_CG_15_0_196_0041.ply", "vh0041"),
    ("VictoryHeart", "VictoryHeart_UVG-CWI-DQPC_CG_15_0_196_0105.ply", "vh0105"),
    ("VirtualLife", "VirtualLife_UVG-CWI-DQPC_CG_15_0_195_0063.ply", "vl0063"),
    ("VirtualLife", "VirtualLife_UVG-CWI-DQPC_CG_15_0_195_0148.ply", "vl0148"),
]


def align_xyz(xyz: np.ndarray, sequence: str) -> np.ndarray:
    return apply_transform(xyz.astype(np.float64), load_align_matrix(sequence)).astype(np.float32)


def cg_point_error(xyz: np.ndarray, he_xyz: np.ndarray) -> np.ndarray:
    tree = cKDTree(he_xyz.astype(np.float64))
    dist, _ = tree.query(xyz.astype(np.float64), k=1, workers=-1)
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


def _projected_box(center, half, elev, azim):
    corners = np.array(
        [[center[0] + sx * half[0], center[1] + sy * half[1], center[2] + sz * half[2]]
         for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)]
    )
    px, py = project_points(corners, elev, azim)
    return float(px.min()), float(px.max()), float(py.min()), float(py.max())


def draw_full(ax, xyz, rgb, center, half, elev, azim, s=0.10):
    """Full-scene view with ROI box."""
    px, py = project_points(xyz, elev, azim)
    ax.scatter(px, py, c=np.clip(rgb, 0, 1), s=s, linewidths=0, rasterized=True)
    x0, x1, y0, y1 = _projected_box(center, half, elev, azim)
    ax.add_patch(Rectangle((x0, y0), x1 - x0, y1 - y0, fill=False, edgecolor="#e53935", linewidth=1.6))
    ax.set_aspect("equal")


def match_he_roi(
    he_xyz: np.ndarray,
    cg_xyz: np.ndarray,
    center: np.ndarray,
    half: np.ndarray,
) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Map CG ROI onto HE (aligned frames can still be ~70–100 mm apart)."""
    cg_m = mask_box(cg_xyz, center, half)
    roi = cg_xyz[cg_m]
    if roi.shape[0] < 40:
        return mask_box(he_xyz, center, half), center, half
    tree = cKDTree(roi.astype(np.float64))
    dist, _ = tree.query(he_xyz.astype(np.float64), k=1, workers=-1)
    thr = max(float(np.percentile(dist, 8)), 95.0)
    m = dist <= thr
    if int(m.sum()) < 80:
        thr = max(float(np.percentile(dist, 15)), 110.0)
        m = dist <= thr
    sub = he_xyz[m]
    he_center = sub.mean(0)
    he_half = np.maximum((sub.max(0) - sub.min(0)) * 0.52, half * 0.45)
    return m, he_center.astype(np.float32), he_half.astype(np.float32)


def zoom_mask_and_box(
    key: str,
    xyz: np.ndarray,
    cg_xyz: np.ndarray,
    center: np.ndarray,
    half: np.ndarray,
) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
    if key == "he":
        return match_he_roi(xyz, cg_xyz, center, half)
    m = mask_box(xyz, center, half)
    return m, center, half


def panel_title(label: str) -> str:
    return label


def column_cd_text(cd: Optional[float], key: str) -> Optional[str]:
    if key == "he" or cd is None:
        return None
    return f"CD {cd:.1f} mm"


def style_column_axes(ax_full, ax_zoom, *, edge: str = "#bdbdbd"):
    for ax in (ax_full, ax_zoom):
        ax.set_aspect("equal")
        ax.set_xticks([])
        ax.set_yticks([])
        for spine in ax.spines.values():
            spine.set_color(edge)
            spine.set_linewidth(0.9)
    for side in ("left", "right"):
        ax_full.spines[side].set_visible(True)
        ax_zoom.spines[side].set_visible(True)
    ax_full.spines["top"].set_visible(True)
    ax_full.spines["bottom"].set_visible(False)
    ax_zoom.spines["top"].set_visible(False)
    ax_zoom.spines["bottom"].set_visible(True)


def render_frame(
    sequence: str,
    cg_name: str,
    slug: str,
    out_dir: Path,
    *,
    elev: float = 16.0,
    azim: float = -72.0,
    max_points: int = 160000,
) -> Optional[Path]:
    enh = cg_name.replace("_CG_", "_ENH_")
    he_name = enh.replace("_ENH_", "_HE_")
    raw = GC2026_ROOT / "data/raw/UVG-CWI-DQPC" / sequence
    cg_path = raw / "consumer-grade_capture_system/CG/15fps" / cg_name
    he_path = raw / "high-end_capture_system/HE/15fps" / he_name
    if not cg_path.is_file() or not he_path.is_file():
        return None

    model_paths = {k: root / sequence / enh for k, _, root in FIVE_MODELS}
    if not all(p.is_file() for p in model_paths.values()):
        missing = [k for k, p in model_paths.items() if not p.is_file()]
        print(f"skip {slug}: missing {missing}", file=sys.stderr)
        return None

    rng = np.random.RandomState(0)
    cg_xyz, cg_rgb = read_ply_xyz_rgb(str(cg_path), max_points=max_points, rng=rng)
    he_xyz, he_rgb = read_ply_xyz_rgb(str(he_path), max_points=max(max_points, 200000), rng=rng)
    cg_al = align_xyz(cg_xyz, sequence)
    he_al = align_xyz(he_xyz, sequence)
    center, half = find_roi(cg_al, he_al, cg_point_error(cg_al, he_al))

    cds: Dict[str, Optional[float]] = {"cg": cd_mm(cg_path, he_path, sequence)}
    clouds: Dict[str, Tuple[np.ndarray, np.ndarray]] = {
        "cg": (cg_al, cg_rgb),
        "he": (he_al, he_rgb),
    }
    for key, _, root in FIVE_MODELS:
        ply = root / sequence / enh
        xyz, rgb = read_ply_xyz_rgb(str(ply), max_points=max_points, rng=rng)
        clouds[key] = (align_xyz(xyz, sequence), rgb)
        cds[key] = cd_mm(ply, he_path, sequence)

    # 7 columns: each column = full (top) + zoom (bottom); CG left, HE right.
    panels: List[Tuple[str, str]] = [("cg", "CG")]
    panels += [(k, lbl) for k, lbl, _ in FIVE_MODELS]
    panels.append(("he", "HE"))
    ncols = len(panels)

    fig = plt.figure(figsize=(2.15 * ncols, 6.6), dpi=200)
    outer = fig.add_gridspec(1, ncols, wspace=0.14)

    for j, (key, label) in enumerate(panels):
        col = outer[j].subgridspec(2, 1, height_ratios=[1.0, 1.08], hspace=0.03)
        xyz, rgb = clouds[key]
        cd = cds.get(key)

        ax_full = fig.add_subplot(col[0])
        m_full, box_center, box_half = zoom_mask_and_box(key, xyz, cg_al, center, half)
        draw_full(ax_full, xyz, rgb, box_center, box_half, elev, azim)
        ax_full.set_title(panel_title(label), fontsize=10, pad=4, fontweight="semibold")

        ax_zoom = fig.add_subplot(col[1])
        m = m_full if key == "he" else mask_box(xyz, center, half)
        px, py = project_points(xyz[m], elev, azim)
        ax_zoom.scatter(px, py, c=np.clip(rgb[m], 0, 1), s=2.4, linewidths=0, rasterized=True)
        set_zoom_limits(ax_zoom, xyz, box_center, box_half, elev, azim)

        cd_txt = column_cd_text(cd, key)
        if cd_txt:
            ax_zoom.text(0.5, -0.06, cd_txt, transform=ax_zoom.transAxes, ha="center", va="top", fontsize=8, color="#444444")

        edge = "#9e9e9e" if key in ("cg", "he") else "#bdbdbd"
        style_column_axes(ax_full, ax_zoom, edge=edge)

    fig.text(
        0.5, 0.008, f"{sequence}  #{frame_id(cg_name)}",
        ha="center", fontsize=8, color="#555555",
    )

    out_dir.mkdir(parents=True, exist_ok=True)
    out_png = out_dir / f"compare5_{slug}.png"
    fig.savefig(out_png, bbox_inches="tight", facecolor="white", pad_inches=0.05)
    plt.close(fig)

    meta = {
        "sequence": sequence,
        "cg_name": cg_name,
        "slug": slug,
        "chamfer_mm": {k: v for k, v in cds.items() if v is not None},
    }
    out_png.with_suffix(".json").write_text(json.dumps(meta, indent=2), encoding="utf-8")
    return out_png


def pick_extra_frames(n: int = 2) -> List[Tuple[str, str, str]]:
    """Frames where Ours vs PD-LTS-FT gap is largest (TrumanShow)."""
    csv_path = GC2026_ROOT / "docs/meeting_delivery/metrics/05_fusion_finetune_pdlts_best_val565.csv"
    ft_csv = GC2026_ROOT / "docs/meeting_delivery/metrics/03_pdlts_finetune_best_val565.csv"
    if not csv_path.is_file() or not ft_csv.is_file():
        return []
    ours = {r["test_file"]: float(r["chamfer_distance"]) for r in csv.DictReader(open(csv_path))}
    ft = {r["test_file"]: float(r["chamfer_distance"]) for r in csv.DictReader(open(ft_csv))}
    rows = []
    for tf in ours:
        if tf not in ft or not tf.startswith("TrumanShow_"):
            continue
        rows.append((ft[tf] - ours[tf], tf))
    rows.sort(reverse=True)
    out = []
    for delta, tf in rows[:n]:
        cg = tf.replace("_ENH_", "_CG_")
        sid = f"ts{frame_id(cg)}"
        out.append(("TrumanShow", cg, sid))
    return out


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--out-dir", default=str(GC2026_ROOT / "docs/meeting_delivery/figures"))
    p.add_argument("--extra-ts", type=int, default=2, help="auto-pick TrumanShow frames with largest Ours gain")
    p.add_argument("--elev", type=float, default=16.0)
    p.add_argument("--azim", type=float, default=-72.0)
    args = p.parse_args()

    out_dir = Path(args.out_dir)
    frames = list(DEFAULT_FRAMES)
    seen = {f[2] for f in frames}
    for item in pick_extra_frames(args.extra_ts):
        if item[2] not in seen:
            frames.append(item)
            seen.add(item[2])

    results = []
    for sequence, cg_name, slug in frames:
        path = render_frame(sequence, cg_name, slug, out_dir, elev=args.elev, azim=args.azim)
        if path:
            results.append(str(path))
            print(path)

    manifest = out_dir / "compare5_manifest.json"
    manifest.write_text(json.dumps({"figures": results}, indent=2), encoding="utf-8")
    print(json.dumps({"count": len(results), "manifest": str(manifest)}, indent=2))


if __name__ == "__main__":
    main()
