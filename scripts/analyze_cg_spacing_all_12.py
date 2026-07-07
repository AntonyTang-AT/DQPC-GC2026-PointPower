#!/usr/bin/env python3
"""
Analyze CG-only statistics across ALL 12 sequences to infer
which sequences are likely to benefit from SuperPC fill.
No PD-LTS primary needed.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import numpy as np
import pandas as pd
from tqdm import tqdm

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

from uvg_io import read_ply_xyz_rgb

ALL_CG_LIST = ROOT / "data/processed/all_cg_only_cgv2.txt"
OUT = ROOT / "output/ft_val565_fusion/holefill_adaptive_frame_gate_v2"


def compute_cg_spacing_stats(xyz: np.ndarray, k: int = 6):
    """Fast NN spacing stats using sklearn."""
    from sklearn.neighbors import NearestNeighbors
    n = xyz.shape[0]
    if n < 2:
        return 0.0, 0.0, 0.0
    k_nn = min(k, n)
    nn = NearestNeighbors(n_neighbors=k_nn, algorithm="auto")
    nn.fit(xyz)
    dists, _ = nn.kneighbors(xyz, return_distance=True)
    local = dists[:, -1]
    pos = local[local > 0]
    if pos.size == 0:
        return 0.0, 0.0, 0.0
    return float(np.median(pos)), float(np.percentile(pos, 90)), float(np.mean(pos))


def main():
    if not ALL_CG_LIST.is_file():
        print(f"ERROR: {ALL_CG_LIST} not found")
        sys.exit(1)

    cg_paths = [l.strip() for l in open(ALL_CG_LIST) if l.strip()]
    print(f"Total CG frames: {len(cg_paths)}")

    # Extract sequence
    seq_from_path = {}
    for cg in cg_paths:
        parts = cg.split("/")
        try:
            idx = parts.index("UVG-CWI-DQPC")
            seq = parts[idx + 1]
        except (ValueError, IndexError):
            seq = "unknown"
        seq_from_path[cg] = seq

    # Sample: take every 10th frame from each sequence to speed up
    by_seq = {}
    for cg, seq in seq_from_path.items():
        by_seq.setdefault(seq, []).append(cg)

    sample_cgs = []
    for seq, paths in by_seq.items():
        sample = sorted(paths)[::10]
        sample_cgs.extend(sample)
        print(f"  {seq:20s}: {len(paths)} total -> {len(sample)} sampled")

    print(f"\nAnalyzing CG-only stats for {len(sample_cgs)} sampled frames...")

    rows = []
    for cg in tqdm(sample_cgs, desc="cg stats"):
        try:
            xyz, _ = read_ply_xyz_rgb(cg)
            n_pts = xyz.shape[0]
            spacing_med, spacing_p90, spacing_mean = compute_cg_spacing_stats(xyz, k=6)
        except Exception as e:
            tqdm.write(f"  skip {Path(cg).name}: {e}")
            continue
        rows.append({
            "cg_path": cg,
            "sequence": seq_from_path.get(cg, "unknown"),
            "n_pts": n_pts,
            "spacing_med_mm": spacing_med,
            "spacing_p90_mm": spacing_p90,
            "spacing_mean_mm": spacing_mean,
        })

    df = pd.DataFrame(rows)

    print(f"\n{'='*80}")
    print(f"CG-only statistics across all 12 sequences (sampled)")
    print(f"{'='*80}")
    print(f"  {'seq':20s} {'n_frames':>9s} {'n_pts_avg':>10s} {'sp_med':>8s} "
          f"{'sp_p90':>8s} {'sp_mean':>8s}")
    print(f"  {'-'*75}")

    for seq, sub in sorted(df.groupby("sequence")):
        marker = " ★" if seq in ("TrumanShow", "VictoryHeart", "VirtualLife") else ""
        print(f"  {seq:20s} {len(sub):>9d} {sub.n_pts.mean():>10.0f} "
              f"{sub.spacing_med_mm.mean():>8.3f} {sub.spacing_p90_mm.mean():>8.3f} "
              f"{sub.spacing_mean_mm.mean():>8.3f}{marker}")

    # Also compute the fraction of frames with high spacing (potential SuperPC benefit)
    print(f"\n{'='*80}")
    print(f"Frames with high CG spacing (potential for SuperPC fill)")
    print(f"{'='*80}")
    for thr in [3.5, 3.8, 4.0, 4.2, 4.5, 5.0]:
        print(f"\n  spacing_p90 > {thr:.1f} mm:")
        for seq, sub in sorted(df.groupby("sequence")):
            high = (sub.spacing_p90_mm > thr).sum()
            pct = 100 * high / len(sub)
            if pct > 0:
                print(f"    {seq:20s}: {high:>4d}/{len(sub):>4d} ({pct:5.1f}%)")

    out_csv = OUT / "cg_spacing_all_12_sequences.csv"
    df.to_csv(out_csv, index=False)
    print(f"\nwrote {out_csv}")


if __name__ == "__main__":
    os.chdir(ROOT)
    main()
