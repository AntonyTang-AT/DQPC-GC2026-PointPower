#!/usr/bin/env python3
"""
Synthesize val565 CD for new skip thresholds using est_add_ratio.

Only reads TrumanShow PLY (171 frames) since VH/VL are skip by default.
Primary sign: est_add_ratio from gate logic determines whether each frame
would be skip / lite / full at the new thresholds.
"""
from __future__ import annotations

import json
import os
import sys
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

import numpy as np
import pandas as pd
from tqdm import tqdm

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "submissions/GC2026_Team_EnhancementOnly/src"))

from enh_refine_config import resolve_preset
from enh_refine_pipeline import output_ply_path
from frame_fill_gate import decide_frame_fill_gate
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


def compute_gate(cg: str, extra: dict) -> dict:
    """Load PLY for one frame and compute gate. Returns dict."""
    try:
        cg_xyz, _ = read_ply_xyz_rgb(cg)
        pr_xyz, _ = read_ply_xyz_rgb(output_ply_path(str(GEOM_PRIMARY), cg))
        sec_path = output_ply_path(str(GEOM_SECONDARY), cg)
        if os.path.isfile(sec_path):
            sec_xyz, _ = read_ply_xyz_rgb(sec_path)
        else:
            sec_xyz = None
    except Exception as e:
        return {"cg_path": cg, "error": str(e)}

    try:
        tier, metrics = decide_frame_fill_gate(cg_xyz, pr_xyz, extra, sec_xyz)
    except Exception as e:
        return {"cg_path": cg, "error": str(e)}

    return {
        "cg_path": cg,
        "tier": tier,
        "est_add_ratio": metrics.get("frame_fill_gate_est_add_ratio", 0.0),
        "spacing_p90": metrics.get("frame_fill_gate_cg_spacing_p90_mm", 0.0),
    }


def main():
    v2 = load_eval(V2_EV)
    ft = load_eval(FT_EV)
    extra = resolve_preset("holefill_adaptive_frame_gate_v2").extra

    cgs_all = sorted(set(v2) & set(ft))
    print(f"Total frames: {len(cgs_all)}")

    # Separate: VH/VL (hard skip, no PLY read needed)
    hard_seqs = ["VictoryHeart", "VirtualLife"]
    hard_cgs = [c for c in cgs_all if v2[c]["sequence"] in hard_seqs]
    adap_cgs = [c for c in cgs_all if v2[c]["sequence"] not in hard_seqs]
    print(f"  hard_skip (VH/VL): {len(hard_cgs)}")
    print(f"  adaptive (TS):     {len(adap_cgs)}")

    # Compute est_add_ratio for adaptive frames in parallel
    raw = []
    n_workers = max(1, os.cpu_count() // 2 or 4)
    print(f"Computing gate for {len(adap_cgs)} frames with {n_workers} workers...")
    with ProcessPoolExecutor(max_workers=n_workers) as pool:
        futs = {pool.submit(compute_gate, cg, extra): cg for cg in adap_cgs}
        for fut in tqdm(as_completed(futs), total=len(adap_cgs), desc="gate"):
            raw.append(fut.result())

    gate_by_cg = {}
    for r in raw:
        if "error" in r and r["error"]:
            print(f"  ERROR {Path(r['cg_path']).name}: {r['error']}")
            continue
        gate_by_cg[r["cg_path"]] = r
    print(f"  computed {len(gate_by_cg)}/{len(adap_cgs)} frames")

    # Build full dataframe
    rows = []
    for cg in cgs_all:
        r_v2, r_ft = v2[cg], ft[cg]
        cd_v2 = r_v2["chamfer_distance"]
        cd_ft = r_ft["chamfer_distance"]
        seq = r_v2["sequence"]

        if seq in hard_seqs:
            est_ar = 0.0
            tier = "skip"
        elif cg in gate_by_cg:
            est_ar = gate_by_cg[cg].get("est_add_ratio", 0.0)
            tier = gate_by_cg[cg].get("tier", "skip")
        else:
            est_ar = 0.0
            tier = "unknown"

        rows.append({
            "cg_path": cg,
            "sequence": seq,
            "frame_id": r_v2.get("frame_id", ""),
            "tier": tier,
            "est_add_ratio": est_ar,
            "cd_v2": cd_v2,
            "cd_ft": cd_ft,
            "cd_diff": cd_v2 - cd_ft,
        })

    df = pd.DataFrame(rows)
    df_v2_cd = df.cd_v2.mean()
    print(f"\nCurrent v2 mean CD: {df_v2_cd:.4f}")
    print(f"ft mean CD:         {df.cd_ft.mean():.4f}")
    print(f"Oracle mean CD:     {df.apply(lambda r: min(r.cd_v2, r.cd_ft), axis=1).mean():.4f}")
    print(f"\nAdaptive tier distrib: {df[~df.sequence.isin(hard_seqs)].tier.value_counts().to_dict()}")

    # ---- Threshold sweep ----
    new_thresholds = [0.010, 0.015, 0.022, 0.030, 0.040, 0.050, 0.060, 0.075, 0.10]

    print(f"\n--- est_add_ratio threshold sweep ---")
    print(f"  {'threshold':>12s}  {'superpc':>8s}  {'skip':>5s}  {'wins':>5s}  {'hurts':>5s}  {'mean_cd':>10s}  {'delta':>8s}")

    n_total = len(df)
    results = []
    for thr in new_thresholds:
        use = df[df.est_add_ratio >= thr]
        skip = df[df.est_add_ratio < thr]
        n_use = len(use)
        n_skip = len(skip)

        wins = int((use.cd_diff < 0).sum())
        hurts = int((use.cd_diff > 0).sum())

        cd_use = use.cd_v2.sum() if n_use > 0 else 0.0
        cd_skip = skip.cd_ft.sum() if n_skip > 0 else 0.0
        new_cd = (cd_use + cd_skip) / n_total
        delta = new_cd - df_v2_cd

        print(f"  {thr:>12.3f}  {n_use:>8d}  {n_skip:>5d}  {wins:>5d}  {hurts:>5d}  {new_cd:>10.4f}  {delta:>+8.4f}")
        results.append({
            "threshold": thr, "use_superpc": n_use, "skip": n_skip,
            "wins": wins, "hurts": hurts,
            "mean_cd": round(new_cd, 4), "delta_vs_v2": round(delta, 4),
        })

    # Per-sequence at current (new) thresholds
    print(f"\n--- Per-sequence at threshold=0.040 ---")
    for seq, sub in df.groupby("sequence"):
        use = sub[sub.est_add_ratio >= 0.040]
        skip_s = sub[sub.est_add_ratio < 0.040]
        cd = (use.cd_v2.sum() + skip_s.cd_ft.sum()) / max(len(sub), 1)
        print(f"  {seq:15s} n={len(sub):3d}  use={len(use):3d}  skip={len(skip_s):3d}  syn_cd={cd:.4f}  "
              f"ft_cd={sub.cd_ft.mean():.4f}  v2_cd={sub.cd_v2.mean():.4f}")

    summary = {
        "baseline_v2_cd": round(float(df_v2_cd), 4),
        "ft_cd": round(float(df.cd_ft.mean()), 4),
        "oracle_cd": round(float(df.apply(lambda r: min(r.cd_v2, r.cd_ft), axis=1).mean()), 4),
        "n_frames": n_total,
        "n_hard_skip": len(hard_cgs),
        "n_adaptive": len(adap_cgs),
        "adaptive_tier_counts": df[~df.sequence.isin(hard_seqs)].tier.value_counts().to_dict(),
        "sweep": results,
    }
    json.dump(summary, open(OUT / "skip_threshold_est_add_ratio.json", "w"), indent=2)
    print(f"\nwrote {OUT / 'skip_threshold_est_add_ratio.json'}")


if __name__ == "__main__":
    os.chdir(ROOT)
    main()
