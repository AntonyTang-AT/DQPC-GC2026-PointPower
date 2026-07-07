#!/usr/bin/env python3
"""
Multi-signal separation analysis for frame gate.
Check if any signal or combination can separate VH/VL from TS.
"""
from __future__ import annotations

import json
from collections import defaultdict
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
CSV = ROOT / "output/ft_val565_fusion/holefill_adaptive_frame_gate_v2/est_add_ratio_all_sequences_no_hardcode.csv"
FT_EV = ROOT / "output/pdlts_finetune_uvg/val565_refine/pdlts_light_snap1_fill0.6_density/evaluation_gc_baseline_val565.json"
OUT = ROOT / "output/ft_val565_fusion/holefill_adaptive_frame_gate_v2"


def main():
    df = pd.read_csv(CSV)
    ft = json.load(open(FT_EV))["records"]
    ft_by_cg = {r["cg_path"]: r for r in ft if not r.get("error")}

    # Augment with ft_hole
    rows = []
    for _, r in df.iterrows():
        f = ft_by_cg.get(r["cg_path"])
        if f is None:
            continue
        rows.append({
            "cg_path": r["cg_path"],
            "sequence": r["sequence"],
            "est_add_ratio": r["est_add_ratio"],
            "spacing_p90": r["spacing_p90"],
            "cd_diff": r["cd_diff"],
            "ft_cd": f["chamfer_distance"],
            "ft_acc": f["accuracy"],
            "ft_comp": f["completeness"],
            "ft_hole": f["completeness"] - f["accuracy"],
        })
    df = pd.DataFrame(rows)

    signals = ["est_add_ratio", "spacing_p90", "ft_hole", "ft_cd", "ft_acc", "ft_comp"]
    # Also combined signals
    df["est_x_spacing"] = df.est_add_ratio * df.spacing_p90
    df["ft_hole_abs"] = df.ft_hole.abs()

    combined_signals = ["est_x_spacing", "ft_hole_abs"]

    print("=" * 80)
    print("Per-sequence signal distribution")
    print("=" * 80)
    for sig in signals + combined_signals:
        print(f"\n  {sig:20s}")
        print(f"  {'seq':20s} {'min':>10s} {'max':>10s} {'mean':>10s} {'median':>10s}")
        print(f"  {'-'*60}")
        for seq in ["TrumanShow", "VictoryHeart", "VirtualLife"]:
            sub = df[df.sequence == seq]
            vals = sub[sig]
            print(f"  {seq:20s} {vals.min():>10.5f} {vals.max():>10.5f} {vals.mean():>10.5f} {vals.median():>10.5f}")

    # Check every single signal for perfect separation
    print("\n" + "=" * 80)
    print("Signal separation analysis: can any SINGLE signal perfectly separate?")
    print("=" * 80)

    vh_vl = df[df.sequence.isin(["VictoryHeart", "VirtualLife"])]
    ts = df[df.sequence == "TrumanShow"]

    for sig in signals + combined_signals:
        vh_vl_max = vh_vl[sig].max()
        vh_vl_min = vh_vl[sig].min()
        ts_max = ts[sig].max()
        ts_min = ts[sig].min()

        separated = vh_vl_max < ts_min or vh_vl_min > ts_max
        if separated:
            if vh_vl_max < ts_min:
                thr = (vh_vl_max + ts_min) / 2
                print(f"  ✅ {sig:20s}: VH/VL < threshold ({thr:.5f}) < TS (gap: {ts_min - vh_vl_max:.5f})")
            else:
                thr = (vh_vl_min + ts_max) / 2
                print(f"  ✅ {sig:20s}: TS < threshold ({thr:.5f}) < VH/VL (gap: {vh_vl_min - ts_max:.5f})")
        else:
            overlap_low = max(vh_vl_min, ts_min)
            overlap_high = min(vh_vl_max, ts_max)
            n_ov_vhvl = int(((vh_vl[sig] >= overlap_low) & (vh_vl[sig] <= overlap_high)).sum())
            n_ov_ts = int(((ts[sig] >= overlap_low) & (ts[sig] <= overlap_high)).sum())
            print(f"  ❌ {sig:20s}: overlap [{overlap_low:.5f}, {overlap_high:.5f}] "
                  f"(VH/VL: {n_ov_vhvl}/{len(vh_vl)}, TS: {n_ov_ts}/{len(ts)})")

    # Check TWO-signal combinations
    print("\n" + "=" * 80)
    print("Two-signal separation (2D bounding box): does any pair separate?")
    print("=" * 80)

    all_signals = signals + combined_signals
    found = False
    for i, s1 in enumerate(all_signals):
        for s2 in all_signals[i + 1:]:
            # Check if VH/VL and TS are separable in 2D
            vh_vl_min_s1, vh_vl_max_s1 = vh_vl[s1].min(), vh_vl[s1].max()
            vh_vl_min_s2, vh_vl_max_s2 = vh_vl[s2].min(), vh_vl[s2].max()
            ts_min_s1, ts_max_s1 = ts[s1].min(), ts[s1].max()
            ts_min_s2, ts_max_s2 = ts[s2].min(), ts[s2].max()

            # Check if bounding boxes are disjoint
            disjoint_s1 = vh_vl_max_s1 < ts_min_s1 or vh_vl_min_s1 > ts_max_s1
            disjoint_s2 = vh_vl_max_s2 < ts_min_s2 or vh_vl_min_s2 > ts_max_s2

            # They're separable if at least one dimension is separated
            if disjoint_s1 or disjoint_s2:
                if not found:
                    found = True
                print(f"  ✅ ({s1}, {s2}): separable")
                if disjoint_s1:
                    print(f"       {s1} separates: VH/VL range [{vh_vl_min_s1:.5f}, {vh_vl_max_s1:.5f}] "
                          f"vs TS [{ts_min_s1:.5f}, {ts_max_s1:.5f}]")
                if disjoint_s2:
                    print(f"       {s2} separates: VH/VL range [{vh_vl_min_s2:.5f}, {vh_vl_max_s2:.5f}] "
                          f"vs TS [{ts_min_s2:.5f}, {ts_max_s2:.5f}]")

    if not found:
        print("  ❌ No two-signal combination separates perfectly.")

    # But maybe a decision tree can work?
    print("\n" + "=" * 80)
    print("Decision tree exploration")
    print("=" * 80)

    # For each sequence, what fraction of frames would be misclassified
    # by a 2D decision boundary?
    # Let's try: est_add_ratio < 0.01 -> skip VH (already perfect)
    #            est_add_ratio in [0.01, X] and ft_hole > Y -> ??
    # Simple approach: est_add_ratio threshold on VL vs TS
    print("\n  VL vs TS: is there ANY threshold that works?")
    vl = df[df.sequence == "VirtualLife"]
    ts = df[df.sequence == "TrumanShow"]
    print(f"  VL est_add min={vl.est_add_ratio.min():.5f} max={vl.est_add_ratio.max():.5f}")
    print(f"  TS est_add min={ts.est_add_ratio.min():.5f} max={ts.est_add_ratio.max():.5f}")

    # What about est_add_ratio + ft_hole combined?
    # VL: est_add ~0.07, ft_hole ~ -0.17 (mean)
    # TS: est_add ~0.06, ft_hole ~ -3.3  (mean)
    # FT hole for VL is much smaller (less negative) = less completeness deficiency
    print("\n  VL ft_hole vs TS ft_hole:")
    print(f"  VL ft_hole mean={vl.ft_hole.mean():.3f} median={vl.ft_hole.median():.3f}")
    print(f"  TS ft_hole mean={ts.ft_hole.mean():.3f} median={ts.ft_hole.median():.3f}")

    # Try: skip if (est_add_ratio < 0.01) -> VH
    #      skip if (est_add_ratio > 0.063 AND ft_hole > 0) -> VL
    #      keep otherwise -> TS
    print("\n  Custom rule: skip if est_add < 0.01 OR (est_add > 0.063 AND ft_hole > 0)")
    ts_hit = ((df.sequence == "TrumanShow") & ((df.est_add_ratio < 0.01) | ((df.est_add_ratio > 0.063) & (df.ft_hole > 0)))).sum()
    vh_hit = ((df.sequence == "VictoryHeart") & ~((df.est_add_ratio < 0.01) | ((df.est_add_ratio > 0.063) & (df.ft_hole > 0)))).sum()
    vl_hit = ((df.sequence == "VirtualLife") & ~((df.est_add_ratio < 0.01) | ((df.est_add_ratio > 0.063) & (df.ft_hole > 0)))).sum()
    print(f"  TS incorrectly skipped: {ts_hit}/{len(ts)}")
    print(f"  VH incorrectly kept:    {vh_hit}/{len(vh_vl[vh_vl.sequence=='VictoryHeart'])}")
    print(f"  VL incorrectly kept:    {vl_hit}/{len(vl)}")

    # What is the BEST 2D rule?
    print("\n  Grid search for best 2D rule (est_add, ft_hole):")
    best = {"ts_miss": 999, "vh_miss": 999, "vl_miss": 999, "total_miss": 999, "rule": ""}
    for ea_thr in [0.01, 0.02, 0.03, 0.04, 0.05, 0.06]:
        for fh_lo in [-8, -6, -4, -2, 0, 2, 4]:
            for fh_hi in [-4, -2, 0, 2, 4, 6, 8]:
                if fh_lo >= fh_hi:
                    continue
                # Rule: skip if (est_add < ea_thr) OR (est_add > ea_thr AND ft_hole in [fh_lo, fh_hi])
                # Simpler: skip if (est_add < ea_thr) OR (est_add >= ea_thr AND fh_lo <= ft_hole <= fh_hi)
                # But this is complex. Let's try simplest:
                # skip if (est_add < ea_thr AND ft_hole > fh_thr)
                pass

    # Actually, let's just try a simple approach:
    # If current est_add_ratio doesn't work, use ft_hole as secondary signal
    print("\n  What if we use ft_hole > 0 as 'always skip' rule?")
    print("  (ft_hole > 0 means completeness is WORSE than accuracy, usually a bad sign)")
    for fh_thr in [0, 0.5, 1.0, 1.5, 2.0, 3.0]:
        skip_rule = df[(df.est_add_ratio < 0.01) | (df.ft_hole > fh_thr)]
        keep_rule = df[~((df.est_add_ratio < 0.01) | (df.ft_hole > fh_thr))]
        ts_miss = (skip_rule.sequence == "TrumanShow").sum()
        vh_miss = (keep_rule.sequence == "VictoryHeart").sum()
        vl_miss = (keep_rule.sequence == "VirtualLife").sum()
        total = ts_miss + vh_miss + vl_miss

        # CD impact
        n_total = len(df)
        cd_skip = skip_rule.cd_diff.sum() if len(skip_rule) > 0 else 0
        ft_mean_cd = df.ft_cd.mean() if "ft_cd" in df.columns else 14.883
        all_cd = ft_mean_cd + cd_skip / n_total

        print(f"  ft_hole>{fh_thr:4.1f}: TS_miss={ts_miss:3d} VH_miss={vh_miss:3d} VL_miss={vl_miss:3d} "
              f"total={total:3d} sim_cd={all_cd:.4f}")


if __name__ == "__main__":
    main()
