#!/usr/bin/env python3
"""
Full analysis: compute est_add_ratio for ALL 564 frames (VH/VL no hardcode).
Then find if a global threshold can separate VH/VL (should skip) from TS (should keep).
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

V2_EV = ROOT / "output/ft_val565_fusion/holefill_adaptive_frame_gate_v2/evaluation_gc_baseline_val565.json"
FT_EV = ROOT / "output/pdlts_finetune_uvg/val565_refine/pdlts_light_snap1_fill0.6_density/evaluation_gc_baseline_val565.json"
GEOM_PRIMARY = ROOT / "output/pdlts_finetune_uvg/val565/light"
GEOM_SECONDARY = ROOT / "output/submission_candidate"
OUT = ROOT / "output/ft_val565_fusion/holefill_adaptive_frame_gate_v2"


def compute_gate(cg: str, extra: dict) -> dict:
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
    v2 = json.load(open(V2_EV))["records"]
    ft = json.load(open(FT_EV))["records"]
    v2_by_cg = {r["cg_path"]: r for r in v2}
    ft_by_cg = {r["cg_path"]: r for r in ft}

    extra = resolve_preset("holefill_adaptive_frame_gate_v2").extra
    # Remove skip_sequences to simulate no hardcode
    extra.pop("frame_fill_gate_skip_sequences", None)

    all_cgs = sorted(set(v2_by_cg) & set(ft_by_cg))
    print(f"Total frames: {len(all_cgs)}")

    # Compute for ALL frames in parallel
    n_workers = max(1, os.cpu_count() // 2 or 4)
    print(f"Computing gate for {len(all_cgs)} frames with {n_workers} workers...")
    raw = []
    with ProcessPoolExecutor(max_workers=n_workers) as pool:
        futs = {pool.submit(compute_gate, cg, extra): cg for cg in all_cgs}
        for fut in tqdm(as_completed(futs), total=len(all_cgs), desc="gate"):
            raw.append(fut.result())

    gate_by_cg = {}
    for r in raw:
        if "error" in r and r["error"]:
            print(f"  ERROR {Path(r['cg_path']).name}: {r['error']}")
            continue
        gate_by_cg[r["cg_path"]] = r
    print(f"  computed {len(gate_by_cg)}/{len(all_cgs)}")

    # Build full dataframe
    rows = []
    for cg in all_cgs:
        r_v2, r_ft = v2_by_cg[cg], ft_by_cg[cg]
        gate = gate_by_cg.get(cg, {})
        rows.append({
            "cg_path": cg,
            "sequence": r_v2["sequence"],
            "frame_id": r_v2.get("frame_id", ""),
            "tier": gate.get("tier", "unknown"),
            "est_add_ratio": gate.get("est_add_ratio", 0.0),
            "spacing_p90": gate.get("spacing_p90", 0.0),
            "cd_v2": r_v2["chamfer_distance"],
            "cd_ft": r_ft["chamfer_distance"],
            "cd_diff": r_v2["chamfer_distance"] - r_ft["chamfer_distance"],
        })
    df = pd.DataFrame(rows)

    # Per-sequence distribution
    print(f"\n{'='*70}")
    print(f"Per-sequence est_add_ratio distribution:")
    print(f"{'='*70}")
    for seq, sub in df.groupby("sequence"):
        ear = sub.est_add_ratio
        print(f"\n  {seq} (n={len(sub)}):")
        print(f"    min     = {ear.min():.5f}")
        print(f"    max     = {ear.max():.5f}")
        print(f"    mean    = {ear.mean():.5f}")
        print(f"    median  = {ear.median():.5f}")
        print(f"    p10     = {ear.quantile(0.10):.5f}")
        print(f"    p25     = {ear.quantile(0.25):.5f}")
        print(f"    p75     = {ear.quantile(0.75):.5f}")
        print(f"    p90     = {ear.quantile(0.90):.5f}")
        print(f"    p95     = {ear.quantile(0.95):.5f}")
        print(f"    p99     = {ear.quantile(0.99):.5f}")

    # Find threshold that separates VH/VL from TS
    vh_vl = df[df.sequence.isin(["VictoryHeart", "VirtualLife"])]
    ts = df[df.sequence == "TrumanShow"]

    vh_vl_max = vh_vl.est_add_ratio.max()
    ts_min = ts.est_add_ratio.min()
    print(f"\n{'='*70}")
    print(f"Separation analysis:")
    print(f"  VH/VL est_add_ratio MAX = {vh_vl_max:.5f}")
    print(f"  TS    est_add_ratio MIN = {ts_min:.5f}")

    if vh_vl_max < ts_min:
        print(f"\n  ✅ PERFECT SEPARATION! Threshold {vh_vl_max:.5f} < x < {ts_min:.5f}")
        print(f"     Any threshold in ({vh_vl_max:.5f}, {ts_min:.5f}) works perfectly.")
        rec = (vh_vl_max + ts_min) / 2
        print(f"     Recommended: {rec:.5f}")
    else:
        overlap_low = max(vh_vl.est_add_ratio.min(), ts.est_add_ratio.min())
        overlap_high = min(vh_vl.est_add_ratio.max(), ts.est_add_ratio.max())
        n_overlap_vhvl = ((vh_vl.est_add_ratio >= overlap_low) & (vh_vl.est_add_ratio <= overlap_high)).sum()
        n_overlap_ts = ((ts.est_add_ratio >= overlap_low) & (ts.est_add_ratio <= overlap_high)).sum()
        print(f"\n  ❌ OVERLAP: [{overlap_low:.5f}, {overlap_high:.5f}]")
        print(f"     VH/VL in overlap: {n_overlap_vhvl}/{len(vh_vl)}")
        print(f"     TS    in overlap: {n_overlap_ts}/{len(ts)}")

    # Sweep thresholds and show sequence breakdown
    print(f"\n{'='*70}")
    print(f"Threshold sweep with sequence breakdown:")
    print(f"{'='*70}")
    print(f"  {'thr':>8s}  {'TS_keep':>8s}  {'TS_skip':>7s}  {'VH_keep':>8s}  {'VH_skip':>7s}  {'VL_keep':>8s}  {'VL_skip':>7s}  {'TS_cd':>8s}  {'all_cd':>8s}")

    n_total = len(df)
    baseline_cd = df.cd_v2.mean()
    for thr in [0.005, 0.01, 0.015, 0.02, 0.025, 0.03, 0.035, 0.04, 0.045, 0.05, 0.06, 0.07]:
        ts_keep = ts[ts.est_add_ratio >= thr]
        ts_skip = ts[ts.est_add_ratio < thr]
        vh_keep = vh_vl[vh_vl.est_add_ratio >= thr]
        vh_skip = vh_vl[vh_vl.est_add_ratio < thr]

        # Simulate CD
        use = df[df.est_add_ratio >= thr]
        skip_s = df[df.est_add_ratio < thr]
        cd = (use.cd_v2.sum() + skip_s.cd_ft.sum()) / n_total

        print(f"  {thr:>8.3f}  {len(ts_keep):>8d}  {len(ts_skip):>7d}  "
              f"{len(vh_keep):>8d}  {len(vh_skip):>7d}  "
              f"{len(vh_keep[vh_keep.sequence=='VirtualLife']):>8d}  "
              f"{len(vh_skip[vh_skip.sequence=='VirtualLife']):>7d}  "
              f"{ts_keep.cd_v2.mean() if len(ts_keep)>0 else 0:>8.4f}  "
              f"{cd:>8.4f}")

    # Write full per-frame CSV
    df.to_csv(OUT / "est_add_ratio_all_sequences_no_hardcode.csv", index=False)
    print(f"\nwrote {OUT / 'est_add_ratio_all_sequences_no_hardcode.csv'}")

    # Summary JSON
    summary = {
        "per_sequence": {
            seq: {
                "n": len(sub),
                "est_add_ratio_min": float(sub.est_add_ratio.min()),
                "est_add_ratio_max": float(sub.est_add_ratio.max()),
                "est_add_ratio_mean": float(sub.est_add_ratio.mean()),
                "est_add_ratio_median": float(sub.est_add_ratio.median()),
                "est_add_ratio_p10": float(sub.est_add_ratio.quantile(0.10)),
                "est_add_ratio_p90": float(sub.est_add_ratio.quantile(0.90)),
            }
            for seq, sub in df.groupby("sequence")
        },
        "separation_possible": bool(vh_vl_max < ts_min),
        "vh_vl_max_est": float(vh_vl_max),
        "ts_min_est": float(ts_min),
        "recommended_threshold": round((vh_vl_max + ts_min) / 2, 5) if vh_vl_max < ts_min else None,
    }
    json.dump(summary, open(OUT / "est_add_ratio_separation_analysis.json", "w"), indent=2)
    print(f"wrote {OUT / 'est_add_ratio_separation_analysis.json'}")


if __name__ == "__main__":
    os.chdir(ROOT)
    main()
