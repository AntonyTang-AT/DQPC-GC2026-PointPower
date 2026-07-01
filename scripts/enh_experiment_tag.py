"""Parse val-grid experiment directory names into enhancement inference params."""
from __future__ import annotations

import re

# Longer names first so filter_blend_cg matches before blend_cg.
OUTPUT_MODES = (
    "filter_blend_cg",
    "blend_filter_cg",
    "fill_cg",
    "filter_cg",
    "blend_cg",
    "model",
)


def parse_experiment_tag(tag: str, grid_root: str = "") -> dict:
    mode = "blend_cg"
    for candidate in OUTPUT_MODES:
        if candidate in tag:
            mode = candidate
            break

    vision = 1 if "_v1_" in tag else 0
    voxel = 1.0
    fill_radius = 1.0
    for seg in tag.split("_"):
        if seg.startswith("vx"):
            try:
                voxel = float(seg[2:])
            except ValueError:
                pass
        if seg.startswith("fr"):
            try:
                fill_radius = float(seg[2:])
            except ValueError:
                pass

    ckpt = tag
    for sep in ("_filter_blend_cg", "_blend_filter_cg", "_fill_cg", "_filter_cg", "_blend_cg", "_model"):
        if sep in ckpt:
            ckpt = ckpt.split(sep)[0]
            break
    if not ckpt.endswith(".pth"):
        ckpt = ckpt + ".pth"

    out: dict = {
        "checkpoint": ckpt,
        "output_mode": mode,
        "blend_voxel_mm": voxel,
        "use_vision": vision,
        "experiment": tag,
    }
    if mode == "fill_cg":
        out["fill_radius_mm"] = fill_radius
    if grid_root:
        import os

        out["experiment_dir"] = os.path.join(grid_root, tag)
    return out


def experiment_tag(
    ckpt_base: str,
    mode: str,
    vision: int = 0,
    voxel: float = 1.0,
    fill_radius: float = 1.0,
) -> str:
    vtag = f"v{vision}"
    if mode == "fill_cg":
        fr = re.sub(r"\.0$", ".0", f"{fill_radius:g}")
        return f"{ckpt_base}_{mode}_{vtag}_fr{fr}"
    if mode in ("filter_cg", "model"):
        vx = "0"
    else:
        vx = re.sub(r"\.0$", ".0", f"{voxel:g}")
    return f"{ckpt_base}_{mode}_{vtag}_vx{vx}"
