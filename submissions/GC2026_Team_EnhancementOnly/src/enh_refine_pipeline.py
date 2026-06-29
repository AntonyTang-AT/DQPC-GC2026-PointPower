"""Apply multi-stage Enh refinement on a single CG frame."""
from __future__ import annotations

import os
from typing import Callable, Optional, Tuple

import numpy as np

from enh_refine_config import FILTER_CG_CONFIG, ROLLBACK_CONFIG, RefineConfig
from uvg_io import (
    filter_cg_outliers,
    merge_cg_model_fill,
    merge_cg_model_fill_density_adaptive,
    merge_xyz_rgb_voxel,
    read_ply_xyz_rgb,
    snap_bidirectional_cg_model,
    snap_xyz_to_reference,
    transfer_colors_knn,
    write_ply_xyz_rgb,
)


def sequence_from_cg_path(cg_path: str) -> str:
    marker = "/UVG-CWI-DQPC/"
    if marker in cg_path:
        return cg_path.split(marker, 1)[1].split("/")[0]
    return os.path.basename(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(cg_path)))))


def output_ply_path(out_dir: str, cg_path: str) -> str:
    seq = sequence_from_cg_path(cg_path)
    fname = os.path.basename(cg_path)
    out_name = fname.replace("_CG_", "_ENH_", 1)
    return os.path.join(out_dir, seq, out_name)


def geometry_ply_path(geometry_dir: str, cg_path: str) -> str:
    return output_ply_path(geometry_dir, cg_path)


def estimate_cg_inlier_ratio(xyz: np.ndarray, rgb: np.ndarray) -> float:
    try:
        filtered_xyz, _ = filter_cg_outliers(xyz, rgb, nb_neighbors=20, std_ratio=2.0)
        return float(filtered_xyz.shape[0]) / max(int(xyz.shape[0]), 1)
    except Exception:
        return 1.0


def adaptive_snap_mm(
    cfg: RefineConfig,
    cg_xyz: np.ndarray,
    cg_rgb: np.ndarray,
    model_xyz: Optional[np.ndarray] = None,
) -> float:
    """Rule-based snap: return effective snap_mm (0 = skip snap, like VH tune)."""
    extra = cfg.extra or {}
    if not extra.get("adaptive_snap"):
        return cfg.snap_mm
    rule = extra.get("adaptive_snap_rule", "inlier")
    if rule == "inlier":
        thresh = float(extra.get("adaptive_snap_inlier_min", 0.97))
        ratio = estimate_cg_inlier_ratio(cg_xyz, cg_rgb)
        if ratio >= thresh:
            return 0.0
        return cfg.snap_mm
    if rule == "geometry_close" and model_xyz is not None and model_xyz.shape[0] > 0:
        from sklearn.neighbors import NearestNeighbors

        nn = NearestNeighbors(n_neighbors=1, algorithm="auto")
        nn.fit(model_xyz)
        dist, _ = nn.kneighbors(cg_xyz, return_distance=True)
        med = float(np.median(dist))
        thresh = float(extra.get("adaptive_snap_geom_median_mm", 0.8))
        if med <= thresh:
            return 0.0
        return cfg.snap_mm
    return cfg.snap_mm


def adaptive_geometry_mode(cfg: RefineConfig, xyz: np.ndarray, rgb: np.ndarray) -> RefineConfig:
    """Per-frame routing: very clean CG -> passthrough; noisy -> keep refine stages."""
    if not cfg.adaptive_route:
        return cfg
    ratio = estimate_cg_inlier_ratio(xyz, rgb)
    n_pts = int(xyz.shape[0])
    out = RefineConfig(**cfg.to_dict())
    if ratio > 0.985 and n_pts > 520000:
        out.geometry = "passthrough_cg"
        out.fill_mm = 0.0
        out.blend_voxel_mm = 0.0
        out.name = cfg.name + "_routed_pass"
        return out
    if ratio > 0.96:
        out.fill_mm = min(out.fill_mm, 0.6)
        out.snap_mm = max(out.snap_mm, 0.5)
        out.name = cfg.name + "_routed_mild"
        return out
    out.name = cfg.name + "_routed_aggressive"
    return out


def resample_geometry_to_cg(
    cg_xyz: np.ndarray,
    cg_rgb: np.ndarray,
    model_xyz: np.ndarray,
    model_rgb: np.ndarray,
) -> Tuple[np.ndarray, np.ndarray]:
    """Fix topology to CG point count (for temporal smooth / stable point count)."""
    if model_xyz.shape[0] == cg_xyz.shape[0]:
        return model_xyz, model_rgb
    out_xyz = snap_xyz_to_reference(cg_xyz, model_xyz, snap_mm=1e9)
    from sklearn.neighbors import NearestNeighbors

    nn = NearestNeighbors(n_neighbors=1, algorithm="auto")
    nn.fit(model_xyz)
    _, idx = nn.kneighbors(cg_xyz, return_distance=True)
    out_rgb = model_rgb[idx[:, 0]]
    # Use nearest model point coords (not cg shell) for geometry
    out_xyz = model_xyz[idx[:, 0]].astype(np.float32)
    return out_xyz, out_rgb.astype(np.float32)


def apply_refine_stages(
    cg_xyz: np.ndarray,
    cg_rgb: np.ndarray,
    cfg: RefineConfig,
    *,
    cg_path: str = "",
    denoise_fn: Optional[Callable[[np.ndarray], np.ndarray]] = None,
    geometry_dir: str = "",
    geometry_fallback: str = "filter_cg",
) -> Tuple[np.ndarray, np.ndarray, dict]:
    """Run configured stages. Always keeps original CG as reference anchor."""
    meta = {"config_name": cfg.name, "geometry": cfg.geometry}
    cfg = adaptive_geometry_mode(cfg, cg_xyz, cg_rgb)
    meta["effective_geometry"] = cfg.geometry

    work_xyz, work_rgb = cg_xyz, cg_rgb
    if cfg.pre_sor:
        work_xyz, work_rgb = filter_cg_outliers(
            work_xyz, work_rgb, nb_neighbors=cfg.pre_sor_nb, std_ratio=cfg.pre_sor_std,
        )
        meta["pre_sor_points"] = int(work_xyz.shape[0])

    ref_xyz, ref_rgb = cg_xyz, cg_rgb

    fill_model_xyz: Optional[np.ndarray] = None
    fill_model_rgb: Optional[np.ndarray] = None

    if cfg.geometry == "passthrough_cg":
        out_xyz, out_rgb = ref_xyz, ref_rgb
    elif cfg.geometry == "filter_cg":
        out_xyz, out_rgb = filter_cg_outliers(ref_xyz, ref_rgb, nb_neighbors=20, std_ratio=2.0)
    elif cfg.geometry in ("pdlts_light", "pdlts_heavy"):
        if denoise_fn is None:
            raise ValueError(f"geometry={cfg.geometry} requires denoise_fn")
        model_xyz = denoise_fn(work_xyz)
        model_rgb = transfer_colors_knn(ref_xyz, ref_rgb, model_xyz, k=1)
        out_xyz, out_rgb = model_xyz, model_rgb
        meta["model_points"] = int(model_xyz.shape[0])
    elif cfg.geometry in ("from_dir", "hybrid_pdlts_superpc"):
        gdir = geometry_dir or cfg.geometry_dir
        if not gdir:
            raise ValueError(f"geometry={cfg.geometry} requires geometry_dir")
        if not cg_path:
            raise ValueError(f"geometry={cfg.geometry} requires cg_path")
        gpath = geometry_ply_path(gdir, cg_path)
        if not os.path.isfile(gpath):
            meta["geometry_miss"] = True
            meta["geometry_miss_path"] = gpath
            fb = geometry_fallback or cfg.geometry_fallback or "filter_cg"
            if fb == "skip":
                raise FileNotFoundError(f"Missing geometry ply: {gpath}")
            fb_cfg = FILTER_CG_CONFIG if fb == "filter_cg" else ROLLBACK_CONFIG
            meta["geometry_fallback"] = fb_cfg.name
            return apply_refine_stages(
                cg_xyz, cg_rgb, fb_cfg, cg_path=cg_path, geometry_fallback=geometry_fallback,
            )
        primary_xyz, primary_rgb = read_ply_xyz_rgb(gpath)
        meta["geometry_path"] = gpath
        out_xyz, out_rgb = primary_xyz, primary_rgb

        if cfg.geometry == "hybrid_pdlts_superpc":
            sec_dir = (cfg.extra or {}).get("geometry_secondary_dir", "")
            fill_role = (cfg.extra or {}).get("hybrid_fill_role", "union_voxel")
            voxel_mm = float((cfg.extra or {}).get("hybrid_voxel_mm", 0.5))
            meta["hybrid_fill_role"] = fill_role
            if sec_dir:
                sec_path = geometry_ply_path(sec_dir, cg_path)
                if os.path.isfile(sec_path):
                    secondary_xyz, secondary_rgb = read_ply_xyz_rgb(sec_path)
                    meta["geometry_secondary_path"] = sec_path
                    meta["hybrid_primary_points"] = int(primary_xyz.shape[0])
                    meta["hybrid_secondary_points"] = int(secondary_xyz.shape[0])
                    if fill_role == "secondary_only":
                        out_xyz, out_rgb = primary_xyz, primary_rgb
                        fill_model_xyz, fill_model_rgb = secondary_xyz, secondary_rgb
                        meta["hybrid_surface"] = "primary"
                        meta["hybrid_fill_source"] = "secondary"
                    else:
                        out_xyz, out_rgb = merge_xyz_rgb_voxel(
                            [primary_xyz, secondary_xyz],
                            [primary_rgb, secondary_rgb],
                            voxel_mm,
                        )
                        fill_model_xyz, fill_model_rgb = out_xyz, out_rgb
                        meta["hybrid_surface"] = "union_voxel"
                        meta["hybrid_fused_points"] = int(out_xyz.shape[0])
                else:
                    meta["geometry_secondary_miss"] = True
                    meta["geometry_secondary_miss_path"] = sec_path
            else:
                meta["geometry_secondary_miss"] = True
    else:
        raise ValueError(f"Unknown geometry mode: {cfg.geometry}")

    if fill_model_xyz is None:
        fill_model_xyz, fill_model_rgb = out_xyz, out_rgb

    if (cfg.extra or {}).get("fp_filter_before_fill") and cfg.fill_mm > 0:
        ref_xyz, ref_rgb = filter_cg_outliers(
            ref_xyz, ref_rgb, nb_neighbors=cfg.pre_sor_nb, std_ratio=cfg.pre_sor_std,
        )
        meta["fp_filter_before_fill"] = True

    if cfg.snap_mm > 0 and cfg.geometry not in ("passthrough_cg", "filter_cg"):
        effective_snap = adaptive_snap_mm(cfg, ref_xyz, ref_rgb, out_xyz)
        if effective_snap > 0:
            if cfg.bidirectional_snap:
                out_xyz, ref_xyz = snap_bidirectional_cg_model(
                    out_xyz, ref_xyz, effective_snap, cfg.cg_pull_mm,
                )
                meta["bidirectional_snap"] = True
                meta["cg_pull_mm"] = cfg.cg_pull_mm
            else:
                out_xyz = snap_xyz_to_reference(out_xyz, ref_xyz, effective_snap)
            fill_model_xyz = snap_xyz_to_reference(fill_model_xyz, ref_xyz, effective_snap)
            meta["snap_mm"] = effective_snap
        else:
            meta["snap_mm"] = 0.0
            meta["adaptive_snap_skip"] = True

    if cfg.fill_mm > 0 and cfg.geometry not in ("passthrough_cg", "filter_cg"):
        if cfg.fill_mode == "density_adaptive":
            out_xyz, out_rgb = merge_cg_model_fill_density_adaptive(
                ref_xyz,
                ref_rgb,
                fill_model_xyz,
                fill_model_rgb,
                cfg.fill_mm,
                k_neighbors=cfg.fill_density_k,
                scale_max=cfg.fill_density_scale_max,
            )
            meta["fill_mode"] = "density_adaptive"
        else:
            out_xyz, out_rgb = merge_cg_model_fill(
                ref_xyz, ref_rgb, fill_model_xyz, fill_model_rgb, cfg.fill_mm,
            )
        meta["fill_mm"] = cfg.fill_mm

    if cfg.blend_voxel_mm > 0:
        out_xyz, out_rgb = merge_xyz_rgb_voxel(
            [ref_xyz, out_xyz], [ref_rgb, out_rgb], cfg.blend_voxel_mm,
        )
        meta["blend_voxel_mm"] = cfg.blend_voxel_mm

    if cfg.post_sor:
        out_xyz, out_rgb = filter_cg_outliers(
            out_xyz, out_rgb, nb_neighbors=cfg.post_sor_nb, std_ratio=cfg.post_sor_std,
        )
        meta["post_sor_points"] = int(out_xyz.shape[0])

    return out_xyz.astype(np.float32), out_rgb.astype(np.float32), meta


def process_cg_frame(
    cg_path: str,
    out_path: str,
    cfg: RefineConfig,
    *,
    denoise_fn: Optional[Callable[[np.ndarray], np.ndarray]] = None,
    geometry_dir: str = "",
    geometry_fallback: str = "filter_cg",
) -> dict:
    cg_xyz, cg_rgb = read_ply_xyz_rgb(cg_path)
    meta = {"cg_path": cg_path, "out_path": out_path}
    out_xyz, out_rgb, stage_meta = apply_refine_stages(
        cg_xyz,
        cg_rgb,
        cfg,
        cg_path=cg_path,
        denoise_fn=denoise_fn,
        geometry_dir=geometry_dir or cfg.geometry_dir,
        geometry_fallback=geometry_fallback,
    )
    meta.update(stage_meta)
    meta["input_points"] = int(cg_xyz.shape[0])
    meta["output_points"] = int(out_xyz.shape[0])
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    write_ply_xyz_rgb(out_path, out_xyz, out_rgb)
    return meta
