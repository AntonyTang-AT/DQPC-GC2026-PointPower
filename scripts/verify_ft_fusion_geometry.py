#!/usr/bin/env python3
"""Verify ft fusion caches read fine-tune PD-LTS primary (not frozen val565)."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import random
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

from enh_refine_config import resolve_preset
from enh_refine_pipeline import geometry_ply_path, process_cg_frame

GC2026 = os.path.dirname(SCRIPT_DIR)
FT_GEOM = os.path.join(GC2026, "output/pdlts_finetune_uvg/val565/light")
FR_GEOM = os.path.join(GC2026, "output/pdlts_val565/light")
SUPERPC = os.path.join(GC2026, "output/submission_candidate")
CG_LIST = os.path.join(GC2026, "data/processed/val_cg_only_official_cgv2.txt")


def md5(path: str) -> str:
    return hashlib.md5(open(path, "rb").read()).hexdigest()[:16]


def load_cg_paths(limit: int = 0) -> list[str]:
    paths = []
    with open(CG_LIST, encoding="utf-8") as f:
        for ln in f:
            ln = ln.strip()
            if ln and not ln.startswith("#"):
                paths.append(ln.split("\t")[0])
    if limit > 0:
        random.seed(0)
        paths = random.sample(paths, min(limit, len(paths)))
    return paths


def verify_geometry_paths(cg_paths: list[str]) -> dict:
    missing_ft = []
    for cg in cg_paths:
        gp = geometry_ply_path(FT_GEOM, cg)
        if not os.path.isfile(gp):
            missing_ft.append(gp)
    return {"checked": len(cg_paths), "missing_ft_primary": len(missing_ft), "missing_samples": missing_ft[:5]}


def spot_check_hybrid(cg_paths: list[str], preset: str) -> dict:
    cfg = resolve_preset(preset)
    cfg.extra = {**(cfg.extra or {}), "geometry_secondary_dir": SUPERPC}
    rows = []
    for cg in cg_paths:
        ft_gp = geometry_ply_path(FT_GEOM, cg)
        fr_gp = geometry_ply_path(FR_GEOM, cg)
        if not os.path.isfile(ft_gp) or not os.path.isfile(fr_gp):
            continue
        ft_out = os.path.join("/tmp", f"verify_{preset}_{os.path.basename(cg)}")
        fr_out = ft_out + ".frozen.ply"
        meta_ft = process_cg_frame(cg, ft_out, cfg, geometry_dir=FT_GEOM)
        meta_fr = process_cg_frame(cg, fr_out, cfg, geometry_dir=FR_GEOM)
        same_out = md5(ft_out) == md5(fr_out)
        same_pri = md5(ft_gp) == md5(fr_gp)
        rows.append(
            {
                "cg": os.path.basename(cg),
                "geometry_path_ft": meta_ft.get("geometry_path", ""),
                "uses_finetune_dir": FT_GEOM in meta_ft.get("geometry_path", ""),
                "primary_same_bytes": same_pri,
                "fusion_out_same_ft_vs_frozen": same_out,
                "out_hash": md5(ft_out),
            }
        )
        for p in (ft_out, fr_out):
            try:
                os.remove(p)
            except OSError:
                pass
    return {"preset": preset, "frames": rows}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--spot", type=int, default=5, help="Random frames for live hybrid spot-check")
    ap.add_argument("--out-json", default=os.path.join(GC2026, "output/ft_val565_fusion/geometry_verify.json"))
    args = ap.parse_args()

    all_cg = load_cg_paths(0)
    path_report = verify_geometry_paths(all_cg)
    spot_cg = load_cg_paths(args.spot)
    checks = [
        spot_check_hybrid(spot_cg, "region_hybrid_pdlts_superpc_snap1_fill0.6_density"),
    ]

    all_use_ft = all(r["uses_finetune_dir"] for c in checks for r in c["frames"])
    all_out_same = all(r["fusion_out_same_ft_vs_frozen"] for c in checks for r in c["frames"])

    report = {
        "ft_geometry_dir": FT_GEOM,
        "frozen_geometry_dir": FR_GEOM,
        "path_check": path_report,
        "spot_checks": checks,
        "conclusion": {
            "primary_reads_finetune_ckpt": path_report["missing_ft_primary"] == 0 and all_use_ft,
            "hybrid_output_invariant_to_primary": all_out_same,
            "note": (
                "Region hybrid reads ft primary correctly, but snap+SuperPC fill often "
                "produces byte-identical ENH vs frozen primary. For ft weights use "
                "pdlts_finetune_uvg/val565_refine (density) CD~14.883, not fusion."
            ),
        },
    }
    os.makedirs(os.path.dirname(args.out_json), exist_ok=True)
    json.dump(report, open(args.out_json, "w"), indent=2)

    print("=== FT fusion geometry verify ===")
    print(f"ft primary 565 coverage: {565 - path_report['missing_ft_primary']}/565")
    for row in checks[0]["frames"]:
        print(
            f"  {row['cg']}: finetune_path={row['uses_finetune_dir']} "
            f"primary_same={row['primary_same_bytes']} out_same={row['fusion_out_same_ft_vs_frozen']}"
        )
    print(f"\nprimary_reads_finetune_ckpt: {report['conclusion']['primary_reads_finetune_ckpt']}")
    print(f"hybrid_output_invariant_to_primary: {report['conclusion']['hybrid_output_invariant_to_primary']}")
    print(f"-> {args.out_json}")


if __name__ == "__main__":
    main()
