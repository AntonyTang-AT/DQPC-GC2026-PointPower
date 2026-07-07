#!/usr/bin/env python3
"""
Analyze frame_gate v2 skip threshold impact on val565 CD.

Uses existing eval JSONs + PLY point count to simulate what would happen
if we raised frame_fill_gate_skip_add_ratio from 0.022 to higher values.

Core assumption: for any frame currently in "full" or "lite" tier,
if we instead skip SuperPC fill, the output CD equals ft CD (primary density refine only).
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

V2_DIR = ROOT / "output/ft_val565_fusion/holefill_adaptive_frame_gate_v2"
V2_EV = V2_DIR / "evaluation_gc_baseline_val565.json"
FT_EV = ROOT / "output/pdlts_finetune_uvg/val565_refine/pdlts_light_snap1_fill0.6_density/evaluation_gc_baseline_val565.json"
OUT = ROOT / "output/ft_val565_fusion/holefill_adaptive_frame_gate_v2"


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
    cgs = sorted(set(v2) & set(ft))
    print(f"frames {len(cgs)}")

    rows = []
    for cg in cgs:
        r_v2, r_ft = v2[cg], ft[cg]
        cd_v2 = r_v2["chamfer_distance"]
        cd_ft = r_ft["chamfer_distance"]
        cd_diff = cd_v2 - cd_ft
        seq = r_v2["sequence"]

        rows.append({
            "cg_path": cg,
            "sequence": seq,
            "frame_id": r_v2.get("frame_id", ""),
            "cd_v2": cd_v2,
            "cd_ft": cd_ft,
            "cd_diff": cd_diff,
            "d_acc": r_v2["accuracy"] - r_ft["accuracy"],
            "d_comp": r_v2["completeness"] - r_ft["completeness"],
        })

    df = pd.DataFrame(rows)

    # Current tier assignment (known from gate logic):
    #   VH/VL: hard skip -> cd == ft exactly
    #   TS: frame_adaptive -> some skip, some lite, some full
    # We don't have per-frame tier logged (infer_meta records empty),
    # but we can infer: if cd_v2 == cd_ft (within 1e-6), it's skip tier.
    df["tier_inferred"] = "unknown"
    df.loc[df.cd_diff.abs() < 1e-6, "tier_inferred"] = "skip"
    df.loc[df.sequence == "VictoryHeart", "tier_inferred"] = "skip (seq)"
    df.loc[df.sequence == "VirtualLife", "tier_inferred"] = "skip (seq)"

    # For frames that are NOT skip (cd_v2 != cd_ft), SuperPC fill was applied.
    # Those are "full" or "lite" tier. We don't know which, but we know they differ from ft.
    non_skip = df[df.tier_inferred == "unknown"]
    skip = df[df.tier_inferred != "unknown"]

    print(f"\nCurrent v2: {df.cd_v2.mean():.4f}")
    print(f"  ft:        {df.cd_ft.mean():.4f}")
    print(f"  avg diff:  {df.cd_diff.mean():+.4f}")
    print(f"  skip frames: {len(skip)} (cd == ft)")
    print(f"  non-skip frames: {len(non_skip)}")

    if len(non_skip) > 0:
        print(f"  non-skip d_avg: {non_skip.cd_diff.mean():+.4f} "
              f"wins={(non_skip.cd_diff<0).sum()} "
              f"hurts={(non_skip.cd_diff>0).sum()}")

    # Threshold sweep on non-skip frames.
    # Simulate: for each frame, we'd skip it if its cd_diff > 0 (hurt) or
    # cd_diff < threshold (small gain not worth it).
    # This gives us the Oracle bound + practical sweeps.

    oracle_cd = df.apply(lambda r: min(r.cd_v2, r.cd_ft), axis=1).mean()
    print(f"\nOracle (perfect per-frame choice): {oracle_cd:.4f}")

    # Which non-skip frames would we save by raising skip threshold?
    # If we raise tau_skip, frames with cd_diff < tau_diff would be skipped.
    print("\n--- Skip threshold sweep over non-skip frames ---")
    print(f"  {'tau_skip(mm)':>14s}  {'non_skip':>8s}  {'forced_skip':>11s}  {'new_cd':>10s}  {'delta':>8s}")

    results = []
    # Current baseline: skip 0.022 * 564 = ~12 frames, no forcing on non-skip
    baseline_cd = df.cd_v2.mean()
    for tau in [0.00, 0.01, 0.02, 0.03, 0.04, 0.05, 0.075, 0.10, 0.15, 0.20, 0.50]:
        # Simulate: non-skip frames with cd_diff < tau -> force skip (use ft cd)
        harmful = non_skip[non_skip.cd_diff > tau]
        keep = non_skip[non_skip.cd_diff <= tau]

        # New CD = skip cd (== ft cd) + keep cd (v2 cd) + harmful cd (forced to ft cd)
        skip_cd = skip.cd_ft.mean() if len(skip) > 0 else 0.0
        keep_cd = keep.cd_v2.mean() if len(keep) > 0 else 0.0
        harmful_cd = harmful.cd_ft.mean() if len(harmful) > 0 else 0.0

        n_skip = len(skip)
        n_keep = len(keep)
        n_harmful = len(harmful)
        n_total = len(df)

        new_cd = (skip_cd * n_skip + keep_cd * n_keep + harmful_cd * n_harmful) / n_total
        delta = new_cd - baseline_cd

        print(f"  {tau:>14.3f}  {n_keep:>8d}  {n_harmful:>11d}  {new_cd:>10.4f}  {delta:>+8.4f}")
        results.append({"tau_skip": tau, "keep": n_keep, "forced_skip": n_harmful, "new_cd": round(new_cd, 4), "delta_vs_v2": round(delta, 4)})

    summary = {
        "v2_cd": round(baseline_cd, 4),
        "ft_cd": round(df.cd_ft.mean(), 4),
        "oracle_cd": round(oracle_cd, 4),
        "n_frames": len(df),
        "skip_by_sequence": {seq: int(len(sub[sub.tier_inferred != "unknown"])) for seq, sub in df.groupby("sequence")},
        "non_skip_by_sequence": {seq: int(len(sub[sub.tier_inferred == "unknown"])) for seq, sub in df.groupby("sequence")},
        "sweep": results,
    }
    json.dump(summary, open(OUT / "skip_threshold_analysis.json", "w"), indent=2)
    print(f"\nwrote {OUT / 'skip_threshold_analysis.json'}")


if __name__ == "__main__":
    os.chdir(ROOT)
    main()
