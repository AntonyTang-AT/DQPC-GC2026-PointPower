#!/usr/bin/env python3
"""Compare per-sequence chamfer: CG vs PD-LTS vs SuperPC refine presets."""
from __future__ import annotations

import argparse
import json
import os
import sys
from collections import defaultdict

import numpy as np

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GC2026_ROOT = os.path.dirname(SCRIPT_DIR)

DEFAULT_EXPERIMENTS = {
    "CG": "output/baselines/val565_cg_gc_baseline.json",
    "pdlts_raw": "output/pdlts_val565/light/evaluation_gc_baseline_val565.json",
    "pdlts_fill0.6": "output/enh_refine_phase2/pdlts_light_snap1_fill0.6/evaluation_gc_baseline_val565.json",
    "superpc_filter": "output/val_grid_official565/kitti360_com_filter_cg_v0_vx0/evaluation_gc_baseline_val565.json",
    "superpc_snap_fill": "output/enh_refine_phase2/superpc_filter_snap1_fill0.6/evaluation_gc_baseline_val565.json",
    "filter_cg": "output/enh_refine_phase2/filter_cg/evaluation_gc_baseline_val565.json",
}


def load_seq_means(path: str) -> dict[str, float]:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    acc: dict[str, list[float]] = defaultdict(list)
    for r in data.get("records", []):
        if r.get("error"):
            continue
        ch = r.get("chamfer_distance")
        if ch is None:
            continue
        acc[r["sequence"]].append(float(ch))
    return {s: float(np.mean(v)) for s, v in acc.items()}


def main() -> None:
    p = argparse.ArgumentParser(description="Per-sequence model preference report")
    p.add_argument("--root", default=GC2026_ROOT)
    p.add_argument("--out-json", default="")
    p.add_argument("--experiments-json", default="", help="JSON map label -> eval path relative to root")
    args = p.parse_args()

    experiments = DEFAULT_EXPERIMENTS
    if args.experiments_json:
        with open(args.experiments_json, encoding="utf-8") as f:
            experiments = json.load(f)

    seq_data: dict[str, dict[str, float]] = {}
    for label, rel in experiments.items():
        path = rel if os.path.isabs(rel) else os.path.join(args.root, rel)
        if not os.path.isfile(path):
            print(f"[skip] missing {label}: {path}", file=sys.stderr)
            continue
        seq_data[label] = load_seq_means(path)

    if "CG" not in seq_data:
        raise SystemExit("CG baseline eval required")

    seqs = sorted(set().union(*[set(v.keys()) for v in seq_data.values()]))
    rows = []
    for seq in seqs:
        cg = seq_data["CG"].get(seq)
        row = {"sequence": seq, "CG": cg}
        for label, means in seq_data.items():
            if label == "CG":
                continue
            m = means.get(seq)
            row[label] = m
            if cg is not None and m is not None:
                row[f"{label}_vs_CG"] = cg - m
        enh_only = {k: v for k, v in row.items() if k not in ("sequence", "CG") and not k.endswith("_vs_CG") and v is not None}
        if enh_only:
            best = min(enh_only, key=enh_only.get)
            row["best_method"] = best
            row["best_chamfer"] = enh_only[best]
        rows.append(row)

    report = {
        "sequences": rows,
        "summary": {
            "num_sequences": len(rows),
            "pdlts_fill_beats_cg": sum(1 for r in rows if (r.get("pdlts_fill0.6_vs_CG") or 0) > 0),
            "superpc_filter_beats_cg": sum(1 for r in rows if (r.get("superpc_filter_vs_CG") or 0) > 0),
            "superpc_snap_fill_beats_cg": sum(1 for r in rows if (r.get("superpc_snap_fill_vs_CG") or 0) > 0),
            "pdlts_raw_beats_cg": sum(1 for r in rows if (r.get("pdlts_raw_vs_CG") or 0) > 0),
        },
        "interpretation": (
            "If all superpc_*_vs_CG are <= 0 on every sequence, SuperPC never beats CG per-seq. "
            "If pdlts_fill0.6_vs_CG > 0 on all sequences, PD-LTS+fill wins uniformly (no seq-specific model flip)."
        ),
    }

    out = args.out_json or os.path.join(args.root, "output/enh_refine_phase2/per_sequence_model_preference.json")
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)

    print(f"Wrote {out}")
    print("sequence       CG   pdlts_f  vs_CG  spc_f   vs_CG  best")
    for r in rows:
        print(
            f"{r['sequence']:14s} {r.get('CG', 0):6.3f} "
            f"{r.get('pdlts_fill0.6', 0):6.3f} {r.get('pdlts_fill0.6_vs_CG', 0):+6.3f} "
            f"{r.get('superpc_filter', 0):6.3f} {r.get('superpc_filter_vs_CG', 0):+6.3f} "
            f"{r.get('best_method', '?')}"
        )
    print("summary:", json.dumps(report["summary"]))


if __name__ == "__main__":
    main()
