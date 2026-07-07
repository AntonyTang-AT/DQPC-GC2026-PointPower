#!/usr/bin/env python3
"""
Analyze est_add_ratio distribution across ALL 12 sequences (val565 + training 9).
Use this to determine if there's a global threshold that separates "skip-worthy"
sequences from "keep-worthy" ones.

The training 9 sequences (1590 frames) give us a broader picture.
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

# Training 9 sequences CG list
ALL_CG_LIST = ROOT / "data/processed/all_cg_only_cgv2.txt"
GEOM_PRIMARY = ROOT / "output/pdlts_finetune_uvg/train/light"
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
    extra = resolve_preset("holefill_adaptive_frame_gate_v2").extra
    extra.pop("frame_fill_gate_skip_sequences", None)

    if not ALL_CG_LIST.is_file():
        print(f"ERROR: {ALL_CG_LIST} not found")
        sys.exit(1)

    cg_paths = [l.strip() for l in open(ALL_CG_LIST) if l.strip()]
    print(f"Total CG frames in list: {len(cg_paths)}")

    # Extract sequence name from path
    seq_from_path = {}
    for cg in cg_paths:
        # Path format: .../UVG-CWI-DQPC/{Sequence}/consumer-grade_capture_system/...
        parts = cg.split("/")
        try:
            idx = parts.index("UVG-CWI-DQPC")
            seq = parts[idx + 1]
        except (ValueError, IndexError):
            seq = "unknown"
        seq_from_path[cg] = seq

    by_seq = {}
    for cg, seq in seq_from_path.items():
        by_seq.setdefault(seq, []).append(cg)
    for seq, paths in sorted(by_seq.items()):
        print(f"  {seq:20s}: {len(paths):>4d} frames")

    # Compute gate for all frames
    all_cgs = sorted(cg_paths)
    n_workers = max(1, os.cpu_count() // 2 or 4)
    print(f"\nComputing gate for {len(all_cgs)} frames with {n_workers} workers...")

    raw = []
    with ProcessPoolExecutor(max_workers=n_workers) as pool:
        futs = {pool.submit(compute_gate, cg, extra): cg for cg in all_cgs}
        for fut in tqdm(as_completed(futs), total=len(all_cgs), desc="gate"):
            raw.append(fut.result())

    gate_by_cg = {}
    for r in raw:
        if "error" in r and r["error"]:
            continue
        gate_by_cg[r["cg_path"]] = r
    print(f"  computed {len(gate_by_cg)}/{len(all_cgs)}")

    # Build dataframe
    rows = []
    for cg in all_cgs:
        g = gate_by_cg.get(cg, {})
        rows.append({
            "cg_path": cg,
            "sequence": seq_from_path.get(cg, "unknown"),
            "tier": g.get("tier", "unknown"),
            "est_add_ratio": g.get("est_add_ratio", 0.0),
            "spacing_p90": g.get("spacing_p90", 0.0),
        })
    df = pd.DataFrame(rows)

    # Per-sequence summary
    print(f"\n{'='*80}")
    print(f"Per-sequence est_add_ratio distribution (all 12 sequences)")
    print(f"{'='*80}")
    print(f"  {'seq':20s} {'n':>5s} {'min':>10s} {'p10':>10s} {'p25':>10s} {'median':>10s} "
          f"{'p75':>10s} {'p90':>10s} {'max':>10s} {'mean':>10s}")
    print(f"  {'-'*105}")

    summary_rows = []
    for seq, sub in sorted(df.groupby("sequence")):
        ear = sub.est_add_ratio
        s = {
            "sequence": seq,
            "n": len(sub),
            "min": ear.min(), "p10": ear.quantile(0.10),
            "p25": ear.quantile(0.25), "median": ear.median(),
            "p75": ear.quantile(0.75), "p90": ear.quantile(0.90),
            "max": ear.max(), "mean": ear.mean(),
        }
        summary_rows.append(s)
        # Color-code: highlight val565 sequences
        marker = " ★" if seq in ("TrumanShow", "VictoryHeart", "VirtualLife") else ""
        print(f"  {seq:20s} {s['n']:>5d} {s['min']:>10.5f} {s['p10']:>10.5f} {s['p25']:>10.5f} "
              f"{s['median']:>10.5f} {s['p75']:>10.5f} {s['p90']:>10.5f} {s['max']:>10.5f} "
              f"{s['mean']:>10.5f}{marker}")

    # Threshold analysis: at current tau_skip=0.022 and proposed tau_skip=0.040
    print(f"\n{'='*80}")
    print(f"Threshold impact across all sequences")
    print(f"{'='*80}")
    print(f"  {'seq':20s} {'n':>5s} {'skip@0.022':>11s} {'skip@0.025':>11s} "
          f"{'skip@0.030':>11s} {'skip@0.040':>11s} {'skip@0.050':>11s}")
    print(f"  {'-'*80}")

    for s in summary_rows:
        seq = s["sequence"]
        sub = df[df.sequence == seq]
        skips = {}
        for thr in [0.022, 0.025, 0.030, 0.040, 0.050]:
            skips[thr] = (sub.est_add_ratio < thr).sum()
        marker = " ★" if seq in ("TrumanShow", "VictoryHeart", "VirtualLife") else ""
        print(f"  {seq:20s} {s['n']:>5d} {skips[0.022]:>10d}  {skips[0.025]:>10d}  "
              f"{skips[0.030]:>10d}  {skips[0.040]:>10d}  {skips[0.050]:>10d}{marker}")

    # Total summary
    print(f"\n{'='*80}")
    print(f"Global statistics")
    print(f"{'='*80}")
    ear_all = df.est_add_ratio
    print(f"  All 12 sequences: n={len(df)} min={ear_all.min():.5f} max={ear_all.max():.5f} "
          f"mean={ear_all.mean():.5f} median={ear_all.median():.5f}")

    # How many frames would each threshold skip?
    for thr in [0.005, 0.010, 0.015, 0.020, 0.022, 0.025, 0.030, 0.035, 0.040, 0.045, 0.050]:
        n_skip = (ear_all < thr).sum()
        pct = 100 * n_skip / len(df)
        n_keep = len(df) - n_skip
        # Which sequences are affected?
        affected = set()
        for seq, sub in df.groupby("sequence"):
            if (sub.est_add_ratio < thr).any() and (sub.est_add_ratio >= thr).any():
                affected.add(seq)
        only_skip_all = set()
        for seq, sub in df.groupby("sequence"):
            if (sub.est_add_ratio < thr).all():
                only_skip_all.add(seq)
        only_keep_all = set()
        for seq, sub in df.groupby("sequence"):
            if (sub.est_add_ratio >= thr).all():
                only_keep_all.add(seq)
        print(f"  thr={thr:.3f}: skip={n_skip:4d}/{pct:5.1f}%  keep={n_keep:4d}  "
              f"full_skip_seqs={sorted(only_skip_all)}  full_keep_seqs={sorted(only_keep_all)}  "
              f"split_seqs={sorted(affected)}")

    out_csv = OUT / "est_add_ratio_all_12_sequences.csv"
    df.to_csv(out_csv, index=False)
    print(f"\nwrote {out_csv}")


if __name__ == "__main__":
    os.chdir(ROOT)
    main()
