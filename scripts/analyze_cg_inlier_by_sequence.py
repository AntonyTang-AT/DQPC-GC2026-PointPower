#!/usr/bin/env python3
"""Per-sequence CG inlier ratio stats (proxy for adaptive snap routing)."""
from __future__ import annotations

import argparse
import json
import os
import sys
from collections import defaultdict

import numpy as np

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GC2026_ROOT = os.path.dirname(SCRIPT_DIR)
sys.path.insert(0, SCRIPT_DIR)

from enh_refine_pipeline import estimate_cg_inlier_ratio  # noqa: E402
from uvg_io import read_ply_xyz_rgb  # noqa: E402


def sequence_from_cg_path(cg_path: str) -> str:
    marker = "/UVG-CWI-DQPC/"
    if marker in cg_path:
        return cg_path.split(marker, 1)[1].split("/")[0]
    return os.path.basename(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(cg_path)))))


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--pairs-file", required=True)
    p.add_argument("--max-per-seq", type=int, default=0, help="0 = all frames in pairs file")
    p.add_argument("--out-json", default="")
    args = p.parse_args()

    with open(args.pairs_file, encoding="utf-8") as f:
        lines = [ln.strip() for ln in f if ln.strip() and not ln.startswith("#")]

    per_seq: dict[str, list[float]] = defaultdict(list)
    for ln in lines:
        cg = ln.split("\t")[0]
        seq = sequence_from_cg_path(cg)
        if args.max_per_seq > 0 and len(per_seq[seq]) >= args.max_per_seq:
            continue
        xyz, rgb = read_ply_xyz_rgb(cg)
        per_seq[seq].append(estimate_cg_inlier_ratio(xyz, rgb))

    rows = []
    for seq in sorted(per_seq):
        vals = per_seq[seq]
        rows.append(
            {
                "sequence": seq,
                "num_frames": len(vals),
                "mean_inlier_ratio": float(np.mean(vals)),
                "min_inlier_ratio": float(np.min(vals)),
                "max_inlier_ratio": float(np.max(vals)),
                "std_inlier_ratio": float(np.std(vals)),
            }
        )

    out = {
        "pairs_file": os.path.abspath(args.pairs_file),
        "sequences": rows,
    }
    path = args.out_json or os.path.join(
        GC2026_ROOT, "output", "adaptive_snap_study", "cg_inlier_by_sequence.json"
    )
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2)
    print(f"Wrote {path}")
    for r in rows:
        print(
            f"{r['sequence']:14s} n={r['num_frames']:4d} "
            f"mean={r['mean_inlier_ratio']:.4f} min={r['min_inlier_ratio']:.4f}"
        )


if __name__ == "__main__":
    main()
