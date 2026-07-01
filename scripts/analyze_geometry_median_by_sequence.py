#!/usr/bin/env python3
"""Median CG->PD-LTS geometry distance per sequence (adaptive snap proxy)."""
from __future__ import annotations

import argparse
import json
import os
import sys
from collections import defaultdict

import numpy as np
from sklearn.neighbors import NearestNeighbors

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GC2026_ROOT = os.path.dirname(SCRIPT_DIR)
sys.path.insert(0, SCRIPT_DIR)

from enh_refine_pipeline import geometry_ply_path, sequence_from_cg_path  # noqa: E402
from uvg_io import read_ply_xyz_rgb  # noqa: E402


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--pairs-file", required=True)
    p.add_argument("--geometry-dir", required=True)
    p.add_argument("--max-per-seq", type=int, default=30)
    p.add_argument("--out-json", default="")
    args = p.parse_args()

    with open(args.pairs_file, encoding="utf-8") as f:
        lines = [ln.strip() for ln in f if ln.strip() and not ln.startswith("#")]

    per_seq: dict[str, list[float]] = defaultdict(list)
    missing = 0
    for ln in lines:
        cg = ln.split("\t")[0]
        seq = sequence_from_cg_path(cg)
        if args.max_per_seq > 0 and len(per_seq[seq]) >= args.max_per_seq:
            continue
        gpath = geometry_ply_path(args.geometry_dir, cg)
        if not os.path.isfile(gpath):
            missing += 1
            continue
        cg_xyz, _ = read_ply_xyz_rgb(cg)
        g_xyz, _ = read_ply_xyz_rgb(gpath)
        nn = NearestNeighbors(n_neighbors=1, algorithm="auto")
        nn.fit(g_xyz)
        dist, _ = nn.kneighbors(cg_xyz, return_distance=True)
        per_seq[seq].append(float(np.median(dist)))

    rows = []
    for seq in sorted(per_seq):
        vals = per_seq[seq]
        rows.append(
            {
                "sequence": seq,
                "num_frames": len(vals),
                "median_dist_mm_mean": float(np.mean(vals)),
                "median_dist_mm_min": float(np.min(vals)),
                "median_dist_mm_max": float(np.max(vals)),
            }
        )

    out = {
        "pairs_file": os.path.abspath(args.pairs_file),
        "geometry_dir": os.path.abspath(args.geometry_dir),
        "geometry_missing": missing,
        "sequences": rows,
    }
    path = args.out_json or os.path.join(
        GC2026_ROOT, "output", "adaptive_snap_study", "geom_median_by_sequence.json"
    )
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2)
    print(f"Wrote {path} (missing_geometry={missing})")
    for r in rows:
        print(f"{r['sequence']:14s} median_dist_mean={r['median_dist_mm_mean']:.4f} mm")


if __name__ == "__main__":
    main()
