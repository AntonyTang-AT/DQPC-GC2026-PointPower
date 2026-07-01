#!/usr/bin/env python3
"""Diagnose Line B (holefill-first) vs ft density: per-seq breakdown and failure modes."""
from __future__ import annotations

import argparse
import json
import os
import sys
from collections import defaultdict
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
GC2026_ROOT = SCRIPT_DIR.parent
sys.path.insert(0, str(SCRIPT_DIR))

FT_EVAL = GC2026_ROOT / "output/pdlts_finetune_uvg/val565_refine/pdlts_light_snap1_fill0.6_density/evaluation_gc_baseline_val565.json"
LINE_B = GC2026_ROOT / "output/ft_val565_fusion/holefill_first_fill0.6_post25_density/evaluation_gc_baseline_val565.json"


def load_records(path: Path) -> list:
    d = json.load(open(path, encoding="utf-8"))
    return d.get("records", d.get("summary", {}).get("records", []))


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--ft-eval", default=str(FT_EVAL))
    p.add_argument("--line-b-eval", default=str(LINE_B))
    p.add_argument("--out-json", default=str(GC2026_ROOT / "output/ft_val565_fusion/lineb_failure_analysis.json"))
    args = p.parse_args()

    ft = {os.path.basename(r["cg_path"]): r for r in load_records(Path(args.ft_eval))}
    lb = {os.path.basename(r["cg_path"]): r for r in load_records(Path(args.line_b_eval))}

    by_seq: dict = defaultdict(list)
    worse_acc = worse_comp = 0
    for cg in ft:
        if cg not in lb:
            continue
        fr, lr = ft[cg], lb[cg]
        seq = fr.get("sequence") or cg.split("_")[0]
        delta = float(lr["chamfer_distance"]) - float(fr["chamfer_distance"])
        dacc = float(lr["accuracy"]) - float(fr["accuracy"])
        dcomp = float(lr["completeness"]) - float(fr["completeness"])
        if dacc > 0.05:
            worse_acc += 1
        if dcomp > 0.05:
            worse_comp += 1
        by_seq[seq].append(
            {
                "cg": cg,
                "delta_cd": delta,
                "dacc": dacc,
                "dcomp": dcomp,
                "ft_cd": float(fr["chamfer_distance"]),
                "line_b_cd": float(lr["chamfer_distance"]),
            }
        )

    seq_summary = {}
    for seq, rows in by_seq.items():
        deltas = [r["delta_cd"] for r in rows]
        seq_summary[seq] = {
            "n": len(rows),
            "mean_delta_cd": sum(deltas) / len(deltas),
            "worse_count": sum(1 for d in deltas if d > 0),
            "mean_dacc": sum(r["dacc"] for r in rows) / len(rows),
            "mean_dcomp": sum(r["dcomp"] for r in rows) / len(rows),
        }

    rows_all = [r for rs in by_seq.values() for r in rs]
    rows_all.sort(key=lambda x: x["delta_cd"], reverse=True)

    report = {
        "diagnosis": {
            "primary_failure_mode": "VictoryHeart: post-SOR after tiny SuperPC fill degrades completeness; "
            "TrumanShow: large SuperPC fill improves completeness.",
            "knobs": [
                "hybrid_max_fill_ratio — cap SuperPC pts vs primary",
                "fill_mm / fill_density_scale_max — tighter CG-hole threshold",
                "adaptive_post_sor — skip post-SOR when fill ratio < 2%",
                "snap_mm=0 — snap-to-CG does not help on dense ft frames",
            ],
            "recommended_presets": [
                "holefill_lite_fill0.25_max3pct_nopost_snap0",
                "holefill_lite_fill0.25_max10pct_adaptive_post25",
            ],
        },
        "sequence_summary": seq_summary,
        "top10_worse": rows_all[:10],
        "top10_better": sorted(rows_all, key=lambda x: x["delta_cd"])[:10],
        "frames_worse_accuracy": worse_acc,
        "frames_worse_completeness": worse_comp,
    }

    out = Path(args.out_json)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
