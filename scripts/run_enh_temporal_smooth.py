#!/usr/bin/env python3
"""Post-process Enh refine output with temporal XYZ smoothing (CPU)."""
from __future__ import annotations

import argparse
import json
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GC2026_ROOT = os.path.dirname(SCRIPT_DIR)
sys.path.insert(0, SCRIPT_DIR)

from enh_temporal import apply_temporal_smooth_dir  # noqa: E402


def main() -> None:
    p = argparse.ArgumentParser(description="Temporal smooth Enh PLY sequences")
    p.add_argument("--in-dir", required=True, help="Input refine root (Seq/*.ply)")
    p.add_argument("--out-dir", required=True, help="Output root")
    p.add_argument("--window", type=int, default=5)
    p.add_argument("--mode", choices=("mean", "ema"), default="mean")
    p.add_argument("--ema-alpha", type=float, default=0.35)
    p.add_argument("--max-correction-mm", type=float, default=10.0,
                   help="Clamp per-point correction magnitude (0=disable)")
    p.add_argument("--sequences", nargs="*", default=None)
    p.add_argument(
        "--cg-root",
        default=os.path.join(GC2026_ROOT, "data/raw/UVG-CWI-DQPC"),
        help="UVG-CWI-DQPC root for CG ply lookup",
    )
    p.add_argument("--in-place", action="store_true", help="Write to temp then replace in-dir")
    args = p.parse_args()

    out_dir = args.out_dir
    if args.in_place:
        out_dir = args.in_dir.rstrip("/") + "_temporal_tmp"
    os.makedirs(out_dir, exist_ok=True)

    stats = apply_temporal_smooth_dir(
        args.in_dir,
        out_dir,
        cg_root=args.cg_root,
        window=args.window,
        mode=args.mode,
        ema_alpha=args.ema_alpha,
        max_correction_mm=args.max_correction_mm,
        sequences=args.sequences,
    )
    meta_path = os.path.join(out_dir, "temporal_smooth_meta.json")
    with open(meta_path, "w", encoding="utf-8") as f:
        json.dump(stats, f, indent=2)

    if args.in_place:
        import shutil

        for seq in os.listdir(out_dir):
            src_seq = os.path.join(out_dir, seq)
            dst_seq = os.path.join(args.in_dir, seq)
            if not os.path.isdir(src_seq) or seq.endswith("_tmp"):
                continue
            os.makedirs(dst_seq, exist_ok=True)
            for fname in os.listdir(src_seq):
                if fname.endswith(".ply"):
                    shutil.move(os.path.join(src_seq, fname), os.path.join(dst_seq, fname))
        shutil.rmtree(out_dir, ignore_errors=True)
        meta_path = os.path.join(args.in_dir, "temporal_smooth_meta.json")
        with open(meta_path, "w", encoding="utf-8") as f:
            json.dump(stats, f, indent=2)

    print(f"[temporal] {stats['frames_out']} frames -> {args.in_dir if args.in_place else out_dir}")


if __name__ == "__main__":
    main()
