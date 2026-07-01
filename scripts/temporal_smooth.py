#!/usr/bin/env python3
"""Temporal sliding-window smoothing on enhanced PLY sequences (XYZ only; colors follow)."""
from __future__ import annotations

import argparse
import sys

SCRIPT_DIR = __file__.rsplit("/", 1)[0]
sys.path.insert(0, SCRIPT_DIR)

from enh_temporal import apply_temporal_smooth_dir  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser(description="Temporal smooth enhanced PLY sequences")
    parser.add_argument("--in-dir", required=True, help="Directory with per-sequence enhanced PLY folders")
    parser.add_argument("--out-dir", required=True, help="Output directory (mirrors structure)")
    parser.add_argument("--window", type=int, default=5, help="Sliding window size (odd recommended)")
    parser.add_argument("--mode", choices=("mean", "ema"), default="mean")
    parser.add_argument("--ema-alpha", type=float, default=0.35)
    parser.add_argument("--sequences", nargs="*", default=None, help="Optional sequence names to process")
    args = parser.parse_args()

    stats = apply_temporal_smooth_dir(
        args.in_dir,
        args.out_dir,
        window=max(1, args.window),
        mode=args.mode,
        ema_alpha=args.ema_alpha,
        sequences=args.sequences,
    )
    print(
        f"Smoothed {stats['frames_out']} frames ({stats.get('skipped_variable_topology', 0)} skipped) "
        f"-> {args.out_dir}"
    )


if __name__ == "__main__":
    main()
