#!/usr/bin/env python3
"""Build official train/val pair list files from all_pairs_cgv2.txt."""
from __future__ import annotations

import argparse
import json
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GC2026_ROOT = os.path.dirname(SCRIPT_DIR)
sys.path.insert(0, SCRIPT_DIR)

from uvg_splits import (  # noqa: E402
    ALL_SEQUENCES,
    OFFICIAL_TRAIN_SEQUENCES,
    OFFICIAL_VAL_SEQUENCES,
    filter_pairs_by_sequences,
    sequence_from_path,
)


def write_lines(path: str, lines: list[str]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
        if lines:
            f.write("\n")


def cg_only_lines(pairs_lines: list[str]) -> list[str]:
    return [ln.split()[0] for ln in pairs_lines if ln.strip()]


def main() -> None:
    p = argparse.ArgumentParser(description="Build official GC2026 split pair files")
    p.add_argument(
        "--all-pairs",
        default=os.path.join(GC2026_ROOT, "data/processed/all_pairs_cgv2.txt"),
    )
    p.add_argument("--out-dir", default=os.path.join(GC2026_ROOT, "data/processed"))
    args = p.parse_args()

    val_lines = filter_pairs_by_sequences(args.all_pairs, set(OFFICIAL_VAL_SEQUENCES))
    train_lines = filter_pairs_by_sequences(args.all_pairs, set(OFFICIAL_TRAIN_SEQUENCES))

    val_pairs = os.path.join(args.out_dir, "val_pairs_official_cgv2.txt")
    train_pairs = os.path.join(args.out_dir, "train_pairs_official_cgv2.txt")
    val_cg = os.path.join(args.out_dir, "val_cg_only_official_cgv2.txt")
    train_cg = os.path.join(args.out_dir, "train_cg_only_official_cgv2.txt")

    write_lines(val_pairs, val_lines)
    write_lines(train_pairs, train_lines)
    write_lines(val_cg, cg_only_lines(val_lines))
    write_lines(train_cg, cg_only_lines(train_lines))

    val_seqs = sorted({sequence_from_path(ln.split()[0]) for ln in val_lines})
    train_seqs = sorted({sequence_from_path(ln.split()[0]) for ln in train_lines})

    meta = {
        "split_spec": "GC2026 Grand Challenge rules §3.2",
        "cg_version": "v2",
        "val_sequences": val_seqs,
        "train_sequences": train_seqs,
        "num_val_frames": len(val_lines),
        "num_train_frames": len(train_lines),
        "val_pairs_file": val_pairs,
        "train_pairs_file": train_pairs,
        "val_cg_only_file": val_cg,
        "train_cg_only_file": train_cg,
        "all_sequences": list(ALL_SEQUENCES),
    }
    meta_path = os.path.join(args.out_dir, "val_meta_official_cgv2.json")
    with open(meta_path, "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2)

    print(f"val_pairs  {len(val_lines):4d} -> {val_pairs}")
    print(f"train_pairs {len(train_lines):4d} -> {train_pairs}")
    print(f"meta -> {meta_path}")
    if val_seqs != list(OFFICIAL_VAL_SEQUENCES):
        raise SystemExit(f"val sequence mismatch: {val_seqs}")
    if train_seqs != list(OFFICIAL_TRAIN_SEQUENCES):
        raise SystemExit(f"train sequence mismatch: {train_seqs}")


if __name__ == "__main__":
    main()
