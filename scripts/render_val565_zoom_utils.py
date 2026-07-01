"""ROI selection and large zoom panels for val565 qualitative figures."""
from __future__ import annotations

from typing import List, Optional, Tuple

import matplotlib.pyplot as plt
import numpy as np
from matplotlib import cm
from matplotlib.patches import Rectangle
from scipy.spatial import cKDTree

from render_val565_qualitative import mask_box, project_points


def scene_bounds(xyz: np.ndarray, q_lo: float = 3.0, q_hi: float = 97.0) -> Tuple[np.ndarray, np.ndarray]:
    mins = np.percentile(xyz, q_lo, axis=0)
    maxs = np.percentile(xyz, q_hi, axis=0)
    return mins.astype(np.float64), maxs.astype(np.float64)


def roi_mean_score(
    xyz: np.ndarray,
    values: np.ndarray,
    center: np.ndarray,
    half: np.ndarray,
    min_pts: int = 80,
) -> Optional[float]:
    m = mask_box(xyz, center, half)
    if int(m.sum()) < min_pts:
        return None
    return float(np.mean(values[m]))


def find_contrast_rois(
    sp_xyz: np.ndarray,
    sp_err: np.ndarray,
    ref_xyz: np.ndarray,
    ref_err: np.ndarray,
    he_xyz: np.ndarray,
    *,
    n_rois: int = 2,
    half_frac: Tuple[float, float, float] = (0.05, 0.05, 0.08),
    min_half_mm: Tuple[float, float, float] = (18.0, 18.0, 35.0),
    grid_u: int = 9,
    grid_v: int = 11,
    w_sp: float = 1.0,
    w_gap: float = 1.5,
    min_sp_err: float = 18.0,
) -> List[Tuple[np.ndarray, np.ndarray, dict]]:
    """
    Pick ROIs where SuperPC error is high AND exceeds reference (PD-LTS) by a large margin.
    Returns list of (center, half, meta).
    """
    mins, maxs = scene_bounds(he_xyz)
    span = maxs - mins
    half = np.maximum(span * np.array(half_frac), np.array(min_half_mm))

    # gap score per SuperPC point (interpolate ref err at sp locations)
    tree_ref = cKDTree(ref_xyz.astype(np.float64))
    _, idx = tree_ref.query(sp_xyz.astype(np.float64), k=1, workers=-1)
    gap_pts = sp_err - ref_err[idx]
    excess_pts = np.maximum(sp_err - float(min_sp_err), 0.0)
    point_score = w_sp * excess_pts + w_gap * np.maximum(gap_pts, 0.0)

    candidates: List[Tuple[float, np.ndarray, np.ndarray]] = []
    for ux in np.linspace(0.18, 0.82, grid_u):
        for uy in np.linspace(0.15, 0.85, grid_v):
            for uz in (0.35, 0.55, 0.72):
                center = mins + span * np.array([ux, uy, uz])
                sc = roi_mean_score(sp_xyz, point_score, center, half, min_pts=60)
                if sc is None:
                    continue
                mean_sp = roi_mean_score(sp_xyz, sp_err, center, half, min_pts=60)
                mean_ref = roi_mean_score(ref_xyz, ref_err, center, half, min_pts=40)
                if mean_sp is None or mean_sp < min_sp_err:
                    continue
                gap = (mean_sp or 0) - (mean_ref or 0)
                if gap < 8.0:
                    continue
                candidates.append((sc, center.copy(), half.copy()))

    candidates.sort(key=lambda x: x[0], reverse=True)
    chosen: List[Tuple[np.ndarray, np.ndarray, dict]] = []
    min_sep = float(np.min(span[:2]) * 0.12)

    for score, center, h in candidates:
        if len(chosen) >= n_rois:
            break
        too_close = any(np.linalg.norm(center[:2] - c[:2]) < min_sep for c, _, _ in chosen)
        if too_close:
            continue
        m_sp = mask_box(sp_xyz, center, h)
        m_ref = mask_box(ref_xyz, center, h)
        meta = {
            "score": score,
            "mean_sp_err_mm": float(np.mean(sp_err[m_sp])) if m_sp.any() else 0.0,
            "mean_ref_err_mm": float(np.mean(ref_err[m_ref])) if m_ref.any() else 0.0,
            "mean_gap_mm": float(np.mean(sp_err[m_sp]) - np.mean(ref_err[m_ref])) if m_sp.any() and m_ref.any() else 0.0,
            "n_sp": int(m_sp.sum()),
        }
        chosen.append((center, h, meta))
    if not chosen and candidates:
        score, center, h = candidates[0]
        m_sp = mask_box(sp_xyz, center, h)
        meta = {"score": score, "mean_sp_err_mm": float(np.mean(sp_err[m_sp])), "mean_gap_mm": 0.0, "n_sp": int(m_sp.sum())}
        chosen.append((center, h, meta))
    return chosen


def projected_box_rect(
    center: np.ndarray,
    half: np.ndarray,
    elev: float,
    azim: float,
) -> Tuple[float, float, float, float]:
    corners = np.array(
        [center + half * np.array([sx, sy, sz]) for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)]
    )
    cpx, cpy = project_points(corners, elev, azim)
    return float(cpx.min()), float(cpx.max()), float(cpy.min()), float(cpy.max())


def set_zoom_limits(ax, xyz: np.ndarray, center: np.ndarray, half: np.ndarray, elev: float, azim: float, pad: float = 0.08) -> None:
    m = mask_box(xyz, center, half)
    if not np.any(m):
        px, py = project_points(xyz, elev, azim)
    else:
        px, py = project_points(xyz[m], elev, azim)
    if px.size == 0:
        return
    dx = (px.max() - px.min()) * pad + 1e-3
    dy = (py.max() - py.min()) * pad + 1e-3
    ax.set_xlim(px.min() - dx, px.max() + dx)
    ax.set_ylim(py.min() - dy, py.max() + dy)


def draw_overview_with_box(
    ax,
    xyz: np.ndarray,
    rgb: np.ndarray,
    center: np.ndarray,
    half: np.ndarray,
    elev: float,
    azim: float,
    title: str,
    label: str = "A",
    s: float = 0.08,
) -> None:
    px, py = project_points(xyz, elev, azim)
    ax.scatter(px, py, c=np.clip(rgb, 0, 1), s=s, linewidths=0, rasterized=True)
    x0, x1, y0, y1 = projected_box_rect(center, half, elev, azim)
    ax.add_patch(Rectangle((x0, y0), x1 - x0, y1 - y0, fill=False, edgecolor="#ff2222", linewidth=2.5, linestyle="-"))
    ax.text(x0, y1, f"  ROI {label}", color="#ff2222", fontsize=10, fontweight="bold", va="bottom")
    ax.set_aspect("equal")
    ax.axis("off")
    ax.set_title(title, fontsize=9)


def draw_rgb_zoom(
    ax,
    xyz: np.ndarray,
    rgb: np.ndarray,
    center: np.ndarray,
    half: np.ndarray,
    elev: float,
    azim: float,
    title: str,
    s: float = 2.5,
) -> None:
    m = mask_box(xyz, center, half)
    sub_xyz, sub_rgb = xyz[m], rgb[m]
    px, py = project_points(sub_xyz, elev, azim)
    ax.scatter(px, py, c=np.clip(sub_rgb, 0, 1), s=s, linewidths=0, rasterized=True)
    set_zoom_limits(ax, xyz, center, half, elev, azim)
    ax.set_aspect("equal")
    ax.axis("off")
    ax.set_title(title, fontsize=9, fontweight="bold")


def draw_err_zoom(
    ax,
    xyz: np.ndarray,
    err: np.ndarray,
    center: np.ndarray,
    half: np.ndarray,
    elev: float,
    azim: float,
    title: str,
    vmax: float,
    s: float = 2.8,
    show_mean: bool = True,
) -> float:
    m = mask_box(xyz, center, half)
    sub_xyz, sub_err = xyz[m], err[m]
    px, py = project_points(sub_xyz, elev, azim)
    colors = cm.get_cmap("turbo")(np.clip(sub_err / max(vmax, 1e-6), 0.0, 1.0))
    ax.scatter(px, py, c=colors, s=s, linewidths=0, rasterized=True)
    set_zoom_limits(ax, xyz, center, half, elev, azim)
    ax.set_aspect("equal")
    ax.axis("off")
    mean_e = float(sub_err.mean()) if sub_err.size else 0.0
    t = f"{title}\nmean={mean_e:.1f} mm" if show_mean else title
    ax.set_title(t, fontsize=9, fontweight="bold")
    return mean_e


def draw_gap_zoom(
    ax,
    sp_xyz: np.ndarray,
    sp_err: np.ndarray,
    ref_xyz: np.ndarray,
    ref_err: np.ndarray,
    center: np.ndarray,
    half: np.ndarray,
    elev: float,
    azim: float,
    title: str,
    vmax: float = 35.0,
    s: float = 2.8,
) -> None:
    """Red = SuperPC much worse than reference in same ROI."""
    m = mask_box(sp_xyz, center, half)
    sub_xyz, sub_e = sp_xyz[m], sp_err[m]
    tree = cKDTree(ref_xyz.astype(np.float64))
    _, idx = tree.query(sub_xyz.astype(np.float64), k=1, workers=-1)
    gap = sub_e - ref_err[idx]
    px, py = project_points(sub_xyz, elev, azim)
    # diverging: white at 0, red positive (SuperPC worse)
    norm_gap = np.clip(gap / max(vmax, 1e-6), 0.0, 1.0)
    colors = cm.get_cmap("YlOrRd")(norm_gap)
    ax.scatter(px, py, c=colors, s=s, linewidths=0, rasterized=True)
    set_zoom_limits(ax, sp_xyz, center, half, elev, azim)
    ax.set_aspect("equal")
    ax.axis("off")
    ax.set_title(f"{title}\nmean Δ={float(gap.mean()):.1f} mm", fontsize=9, fontweight="bold")


def point_dist_to_cloud(xyz: np.ndarray, ref_xyz: np.ndarray) -> np.ndarray:
    """Per-point distance to nearest neighbor in ref (same coordinate frame)."""
    if xyz.shape[0] == 0 or ref_xyz.shape[0] == 0:
        return np.zeros(xyz.shape[0], dtype=np.float32)
    tree = cKDTree(ref_xyz.astype(np.float64))
    dist, _ = tree.query(xyz.astype(np.float64), k=1, workers=-1)
    return dist.astype(np.float32)


def find_cg_drift_rois(
    sp_xyz: np.ndarray,
    sp_cg_dist: np.ndarray,
    ref_xyz: np.ndarray,
    ref_cg_dist: np.ndarray,
    cg_xyz: np.ndarray,
    *,
    n_rois: int = 2,
    half_frac: Tuple[float, float, float] = (0.05, 0.05, 0.08),
    min_half_mm: Tuple[float, float, float] = (18.0, 18.0, 35.0),
    min_sp_cg_mm: float = 6.0,
    min_gap_mm: float = 4.0,
) -> List[Tuple[np.ndarray, np.ndarray, dict]]:
    """ROIs where ENH points drift from CG (SuperPC >> density)."""
    mins, maxs = scene_bounds(cg_xyz)
    span = maxs - mins
    half = np.maximum(span * np.array(half_frac), np.array(min_half_mm))

    tree_ref = cKDTree(ref_xyz.astype(np.float64))
    _, idx = tree_ref.query(sp_xyz.astype(np.float64), k=1, workers=-1)
    gap_pts = sp_cg_dist - ref_cg_dist[idx]
    point_score = sp_cg_dist + 1.5 * np.maximum(gap_pts, 0.0)

    candidates: List[Tuple[float, np.ndarray, np.ndarray]] = []
    for ux in np.linspace(0.18, 0.82, 9):
        for uy in np.linspace(0.15, 0.85, 11):
            for uz in (0.35, 0.55, 0.72):
                center = mins + span * np.array([ux, uy, uz])
                sc = roi_mean_score(sp_xyz, point_score, center, half, min_pts=50)
                if sc is None:
                    continue
                mean_sp = roi_mean_score(sp_xyz, sp_cg_dist, center, half, min_pts=50)
                mean_ref = roi_mean_score(ref_xyz, ref_cg_dist, center, half, min_pts=30)
                if mean_sp is None or mean_sp < min_sp_cg_mm:
                    continue
                gap = (mean_sp or 0) - (mean_ref or 0)
                if gap < min_gap_mm:
                    continue
                candidates.append((sc, center.copy(), half.copy()))

    candidates.sort(key=lambda x: x[0], reverse=True)
    chosen: List[Tuple[np.ndarray, np.ndarray, dict]] = []
    min_sep = float(np.min(span[:2]) * 0.12)
    for score, center, h in candidates:
        if len(chosen) >= n_rois:
            break
        if any(np.linalg.norm(center[:2] - c[:2]) < min_sep for c, _, _ in chosen):
            continue
        m_sp = mask_box(sp_xyz, center, h)
        m_ref = mask_box(ref_xyz, center, h)
        meta = {
            "score": score,
            "mean_sp_cg_mm": float(np.mean(sp_cg_dist[m_sp])) if m_sp.any() else 0.0,
            "mean_ref_cg_mm": float(np.mean(ref_cg_dist[m_ref])) if m_ref.any() else 0.0,
            "mean_cg_gap_mm": float(np.mean(sp_cg_dist[m_sp]) - np.mean(ref_cg_dist[m_ref]))
            if m_sp.any() and m_ref.any()
            else 0.0,
            "n_sp": int(m_sp.sum()),
        }
        chosen.append((center, h, meta))
    if not chosen and candidates:
        score, center, h = candidates[0]
        m_sp = mask_box(sp_xyz, center, h)
        meta = {
            "score": score,
            "mean_sp_cg_mm": float(np.mean(sp_cg_dist[m_sp])),
            "mean_cg_gap_mm": 0.0,
            "n_sp": int(m_sp.sum()),
        }
        chosen.append((center, h, meta))
    return chosen


def draw_cg_gap_zoom(
    ax,
    sp_xyz: np.ndarray,
    sp_cg: np.ndarray,
    ref_xyz: np.ndarray,
    ref_cg: np.ndarray,
    center: np.ndarray,
    half: np.ndarray,
    elev: float,
    azim: float,
    title: str,
    vmax: float = 15.0,
    s: float = 2.8,
) -> None:
    """Red = SuperPC farther from CG than density."""
    m = mask_box(sp_xyz, center, half)
    sub_xyz, sub_d = sp_xyz[m], sp_cg[m]
    tree = cKDTree(ref_xyz.astype(np.float64))
    _, idx = tree.query(sub_xyz.astype(np.float64), k=1, workers=-1)
    gap = sub_d - ref_cg[idx]
    px, py = project_points(sub_xyz, elev, azim)
    colors = cm.get_cmap("YlOrRd")(np.clip(gap / max(vmax, 1e-6), 0.0, 1.0))
    ax.scatter(px, py, c=colors, s=s, linewidths=0, rasterized=True)
    set_zoom_limits(ax, sp_xyz, center, half, elev, azim)
    ax.set_aspect("equal")
    ax.axis("off")
    ax.set_title(f"{title}\nmean Δ={float(gap.mean()):.1f} mm", fontsize=9, fontweight="bold")


def draw_cg_overlay_zoom(
    ax,
    enh_xyz: np.ndarray,
    enh_cg_dist: np.ndarray,
    cg_xyz: np.ndarray,
    cg_rgb: np.ndarray,
    center: np.ndarray,
    half: np.ndarray,
    elev: float,
    azim: float,
    title: str,
    vmax: float,
    s_enh: float = 4.0,
    s_cg: float = 1.5,
) -> None:
    """CG gray underlay + ENH colored by distance to CG."""
    m_cg = mask_box(cg_xyz, center, half)
    m_enh = mask_box(enh_xyz, center, half)
    if m_cg.any():
        px, py = project_points(cg_xyz[m_cg], elev, azim)
        ax.scatter(px, py, c="0.75", s=s_cg, linewidths=0, rasterized=True, alpha=0.6)
    if m_enh.any():
        sub_xyz, sub_d = enh_xyz[m_enh], enh_cg_dist[m_enh]
        px, py = project_points(sub_xyz, elev, azim)
        colors = cm.get_cmap("turbo")(np.clip(sub_d / max(vmax, 1e-6), 0.0, 1.0))
        ax.scatter(px, py, c=colors, s=s_enh, linewidths=0, rasterized=True)
    set_zoom_limits(ax, enh_xyz, center, half, elev, azim)
    ax.set_aspect("equal")
    ax.axis("off")
    mean_d = float(enh_cg_dist[m_enh].mean()) if m_enh.any() else 0.0
    ax.set_title(f"{title}\nmean dist→CG={mean_d:.1f} mm", fontsize=9, fontweight="bold")
