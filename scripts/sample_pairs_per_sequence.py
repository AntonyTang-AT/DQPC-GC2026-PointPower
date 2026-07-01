#!/usr/bin/env python3
"""Build stratified sample pairs (N frames per sequence) for fast PD-LTS eval."""
from __future__ import annotations

import argparse
import os
import random
from collections import defaultdict


def sequence_from_cg(cg: str) -> str:
    marker = "/UVG-CWI-DQPC/"
    if marker in cg:
        return cg.split(marker, 1)[1].split("/")[0]
    return os.path.basename(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(cg)))))


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--pairs-file", required=True)
    p.add_argument("--out-file", required=True)
    p.add_argument("--per-seq", type=int, default=25)
    p.add_argument("--seed", type=int, default=42)
    args = p.parse_args()

    by_seq: dict[str, list[str]] = defaultdict(list)
    with open(args.pairs_file, encoding="utf-8") as f:
        for ln in f:
            ln = ln.strip()
            if not ln or ln.startswith("#"):
                continue
            cg = ln.split("\t")[0]
            by_seq[sequence_from_cg(cg)].append(ln)

    rng = random.Random(args.seed)
    picked: list[str] = []
    for seq in sorted(by_seq):
        pool = by_seq[seq]
        n = min(args.per_seq, len(pool))
        picked.extend(rng.sample(pool, n))

    os.makedirs(os.path.dirname(args.out_file) or ".", exist_ok=True)
    with open(args.out_file, "w", encoding="utf-8") as f:
        f.write("\n".join(picked) + "\n")
    print(f"Wrote {args.out_file} frames={len(picked)} sequences={len(by_seq)}")


if __name__ == "__main__":
    main()
