#!/usr/bin/env python3
"""
Analyze frame_gate v2 skip threshold using est_add_ratio (real gate signal).

Reads CG PD-LTS secondary PLY -> runs decide_frame_fill_gate with varying
skip thresholds -> simulates CD impact by looking up known CD from eval JSON.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import numpy as np
import pandas as pd
from tqdm import tqdm

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

from enh_refine_config import resolve_preset
from enh_refine_pipeline import output_ply_path
from frame_fill_gate import decide_frame_fill_gate, tier_fill_overrides
from uvg_io import read_ply_xyz_rgb

V2_DIR = ROOT / "output/ft_val565_fusion/holefill_adaptive_frame_gate_v2"
V2_EV = V2_DIR / "evaluation_gc_baseline_val565.json"
FT_EV = ROOT / "output/pdlts_finetune_uvg/val565_refine/pdlts_light_snap1_fill0.6_density/evaluation_gc_baseline_val565.json"
GEOM_PRIMARY = ROOT / "output/pdlts_finetune_uvg/val565/light"
GEOM_SECONDARY = ROOT / "output/submission_candidate"
OUT = V2_DIR


def load_eval(path: Path) -> dict:
    idx = {}
    for r in json.load(open(path, encoding="utf-8"))["records"]:
        if r.get("error"):
            continue
        idx[r["cg_path"]] = r
    return idx


def main():
    v2 = load_eval(V2_EV)
    ft = load_eval(FT_EV)

    extra = resolve_preset("holefill_adaptive_frame_gate_v2").extra
    cgs_sorted = sorted(set(v2) & set(ft))
    print(f"frames {len(cgs_sorted)}")

    sweep_thresholds = [0.010, 0.015, 0.022, 0.030, 0.040, 0.050, 0.075, 0.10, 0.15]

    # Per-frame data
    per_frame = []

    for cg in tqdm(cgs_sorted, desc="loading"):
        r_v2 = v2[cg]
        r_ft = ft[cg]
        seq = r_v2["sequence"]

        # Check if this seq is hard-skipped (VH/VL)
        if seq in extra.get("frame_fill_gate_skip_sequences", []):
            per_frame.append({
                "cg_path": cg, "sequence": seq, "frame_id": r_v2.get("frame_id", ""),
                "est_add_ratio": 0.0,  # no gate computation
                "cd_v2": r_v2["chamfer_distance"],
                "cd_ft": r_ft["chamfer_distance"],
                "cd_diff": r_v2["chamfer_distance"] - r_ft["chamfer_distance"],
                "hard_skip": True,
            })
            continue

        # Read PLY for non-hard-skip sequences
        try:
            cg_xyz, _ = read_ply_xyz_rgb(cg)
            pr_xyz, _ = read_ply_xyz_rgb(output_ply_path(str(GEOM_PRIMARY), cg))
            sec_path = output_ply_path(str(GEOM_SECONDARY), cg)
            if os.path.isfile(sec_path):
                sec_xyz, _ = read_ply_xyz_rgb(sec_path)
            else:
                sec_xyz = None
        except Exception as e:
            tqdm.write(f"skip {cg}: {e}")
            continue

        try:
            tier, metrics = decide_frame_fill_gate(cg_xyz, pr_xyz, extra, sec_xyz)
        except Exception as e:
            tqdm.write(f"gate failed {cg}: {e}")
            continue

        per_frame.append({
            "cg_path": cg, "sequence": seq, "frame_id": r_v2.get("frame_id", ""),
            "tier": tier,
            "est_add_ratio": metrics.get("frame_fill_gate_est_add_ratio", 0.0),
            "spacing_p90": metrics.get("frame_fill_gate_cg_spacing_p90_mm", 0.0),
            "cd_v2": r_v2["chamfer_distance"],
            "cd_ft": r_ft["chamfer_distance"],
            "cd_diff": r_v2["chamfer_distance"] - r_ft["chamfer_distance"],
            "hard_skip": False,
        })

    df = pd.DataFrame(per_frame)
    print(f"\nLoaded {len(df)} frames")

    # Separate hard-skipped and adaptive
    hard = df[df.hard_skip]
    adaptive = df[~df.hard_skip]
    print(f"  hard_skip: {len(hard)} (VH/VL)")
    print(f"  adaptive:  {len(adaptive)}")
    print(f"  adaptive tiers: {adaptive.tier.value_counts().to_dict()}")

    print(f"\nCurrent (v2): hard({len(hard)}) + adaptive({len(adaptive)}) = mean={df.cd_v2.mean():.4f}")
    print(f"Oracle (perfect per-frame choice): {df.apply(lambda r: min(r.cd_v2, r.cd_ft), axis=1).mean():.4f}")

    # Reference CD: what if we skip SuperPC on ALL adaptive frames (use ft CD)
    all_skip_cd = (hard.cd_v2.sum() + adaptive.cd_ft.sum()) / len(df)
    print(f"All skip adaptive: {all_skip_cd:.4f}")

    # Threshold sweep on est_add_ratio
    print(f"\n--- est_add_ratio threshold sweep ---")
    print(f"  {'threshold':>12s}  {'use_superpc':>11s}  {'wins':>5s}  {'hurts':>6s}  {'mean_cd':>10s}  {'delta':>8s}")

    baseline_cd = df.cd_v2.mean()
    results = []
    for thr in sweep_thresholds:
        # Adaptive frames with est_add_ratio >= thr -> use SuperPC (v2 CD)
        # Adaptive frames with est_add_ratio <  thr -> use ft CD
        use = adaptive[adaptive.est_add_ratio >= thr]
        skip = adaptive[adaptive.est_add_ratio < thr]

        n_use = len(use)
        n_skip_adap = len(skip)
        wins = int((use.cd_diff < 0).sum())
        hurts = int((use.cd_diff > 0).sum())

        cd_use = use.cd_v2.sum() if n_use > 0 else 0.0
        cd_skip = skip.cd_ft.sum() if n_skip_adap > 0 else 0.0
        cd_hard = hard.cd_v2.sum()

        new_cd = (cd_hard + cd_use + cd_skip) / len(df)
        delta = new_cd - baseline_cd

        print(f"  {thr:>12.3f}  {n_use:>11d}  {wins:>5d}  {hurts:>6d}  {new_cd:>10.4f}  {delta:>+8.4f}")
        results.append({
            "threshold": thr,
            "use_superpc": n_use,
            "wins": wins,
            "hurts": hurts,
            "mean_cd": round(new_cd, 4),
            "delta_vs_v2": round(delta, 4),
        })

    # Also show per-sequence for current est_add_ratio distribution
    print(f"\n--- Per-sequence est_add_ratio distribution ---")
    for seq, sub in adaptive.groupby("sequence"):
        print(f"  {seq:15s} n={len(sub):3d}  "
              f"mean_est={sub.est_add_ratio.mean():.4f}  "
              f"p90_est={sub.est_add_ratio.quantile(0.9):.4f}  "
              f"wins={int((sub.cd_diff<0).sum()):3d}  "
              f"hurts={int((sub.cd_diff>0).sum()):3d}  "
              f"mean_diff={sub.cd_diff.mean():+.4f}")

    summary = {
        "baseline_v2_cd": round(baseline_cd, 4),
        "ft_cd": round(df.cd_ft.mean(), 4),
        "oracle_cd": round(df.apply(lambda r: min(r.cd_v2, r.cd_ft), axis=1).mean(), 4),
        "n_frames": len(df),
        "n_hard_skip": len(hard),
        "n_adaptive": len(adaptive),
        "adaptive_tiers": adaptive.tier.value_counts().to_dict(),
        "all_skip_adaptive_cd": round(all_skip_cd, 4),
        "sweep": results,
        "per_sequence": {
            seq: {
                "n": int(len(sub)),
                "mean_est_add_ratio": round(float(sub.est_add_ratio.mean()), 4),
                "mean_cd_diff": round(float(sub.cd_diff.mean()), 4),
                "wins": int((sub.cd_diff < 0).sum()),
                "hurts": int((sub.cd_diff > 0).sum()),
            }
            for seq, sub in adaptive.groupby("sequence")
        },
    }
    json.dump(summary, open(OUT / "skip_threshold_analysis_v2.json", "w"), indent=2)
    print(f"\nwrote {OUT / 'skip_threshold_analysis_v2.json'}")


if __name__ == "__main__":
    os.chdir(ROOT)
    main()
