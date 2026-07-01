#!/usr/bin/env python3
"""Full Pipeline: aligned GC baseline metrics for recon CG + ENH vs HE.

Uses the same definitions as evaluate_gc_baseline_metrics.py / ACMMM26_GC_baseline.csv:
  - alignment matrix applied to test cloud (recon CG or ENH)
  - chamfer_distance = (accuracy + completeness) / 2
  - fscore@10 uses dist < 10 mm
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from concurrent.futures import ProcessPoolExecutor, as_completed
from datetime import datetime

import numpy as np
from tqdm import tqdm

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GC2026_ROOT = os.path.dirname(SCRIPT_DIR)
sys.path.insert(0, SCRIPT_DIR)

from evaluate_gc_baseline_metrics import (  # noqa: E402
    _worker_task,
    aggregate_metrics,
    metric_keys,
    write_csv,
)
from evaluate_recon_pipeline import enh_path_from_recon_cg, load_pairs  # noqa: E402
from uvg_io import parse_frame_id  # noqa: E402


def sequence_from_recon_path(recon_path: str) -> str:
    return os.path.basename(os.path.dirname(recon_path))


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Full Pipeline GC baseline-compatible metrics")
    p.add_argument(
        "--pairs-file",
        default=os.path.join(
            GC2026_ROOT, "output/full_pipeline_n0_v2_cg/recon_he_pairs_official_val565.txt"
        ),
        help="Tab-separated recon_cg\\tHE paths",
    )
    p.add_argument(
        "--recon-list",
        default=os.path.join(
            GC2026_ROOT, "output/full_pipeline_n0_v2_cg/reconstructed_cg_list.txt"
        ),
        help="Fallback if --pairs-file missing",
    )
    p.add_argument(
        "--enhanced-root",
        default=os.path.join(GC2026_ROOT, "output/full_pipeline_n0_v2_candidate"),
    )
    p.add_argument("--thresholds", default="10,20,30,50")
    p.add_argument("--max-load-points", type=int, default=0, help="0 = full point cloud")
    p.add_argument("--max-frames", type=int, default=0)
    p.add_argument("--workers", type=int, default=8)
    p.add_argument("--seed", type=int, default=21)
    p.add_argument("--out-json", required=True)
    p.add_argument("--out-csv", default=None)
    p.add_argument(
        "--also-recon-cg",
        action="store_true",
        default=True,
        help="Also score aligned recon CG vs HE (stage1 baseline for this track)",
    )
    p.add_argument(
        "--no-also-recon-cg",
        action="store_false",
        dest="also_recon_cg",
    )
    return p.parse_args()


def build_tasks(args: argparse.Namespace) -> list[dict]:
    pairs_file = args.pairs_file if os.path.isfile(args.pairs_file) else None
    pairs = load_pairs(args.recon_list, pairs_file)
    if args.max_frames > 0:
        pairs = pairs[: args.max_frames]

    thresholds = tuple(float(x) for x in args.thresholds.split(",") if x.strip())
    tasks: list[dict] = []
    for idx, (recon_path, he_path) in enumerate(pairs):
        seq = sequence_from_recon_path(recon_path)
        enh_path = enh_path_from_recon_cg(recon_path, args.enhanced_root)
        if not os.path.isfile(recon_path) or not os.path.isfile(he_path):
            continue
        if not os.path.isfile(enh_path):
            continue
        tasks.append(
            {
                "test_path": enh_path,
                "gt_path": he_path,
                "sequence": seq,
                "thresholds": thresholds,
                "max_load_points": args.max_load_points,
                "seed": args.seed + idx,
                "frame_id": parse_frame_id(recon_path),
                "cg_path": recon_path if args.also_recon_cg else None,
                "also_cg": args.also_recon_cg,
                "recon_path": recon_path,
            }
        )
    return tasks


def main() -> None:
    args = parse_args()
    tasks = build_tasks(args)
    if not tasks:
        raise SystemExit("No evaluable Full Pipeline frames found")

    thresholds = tasks[0]["thresholds"]
    records: list[dict] = []
    if args.workers <= 1:
        for payload in tqdm(tasks, desc="fp_gc_metrics"):
            rec = _worker_task(payload)
            if rec:
                records.append(rec)
    else:
        with ProcessPoolExecutor(max_workers=args.workers) as pool:
            futures = [pool.submit(_worker_task, p) for p in tasks]
            for fut in tqdm(as_completed(futures), total=len(futures), desc="fp_gc_metrics"):
                rec = fut.result()
                if rec:
                    records.append(rec)

    records.sort(key=lambda r: (r.get("sequence", ""), r.get("frame_id", "")))
    keys = metric_keys(thresholds)
    ok = [r for r in records if not r.get("error")]
    cg_chamfer = [float(r["cg_chamfer_distance"]) for r in ok if "cg_chamfer_distance" in r]
    enh_chamfer = [float(r["chamfer_distance"]) for r in ok if "chamfer_distance" in r]
    deltas = [float(r["delta_cg_minus_enh"]) for r in ok if "delta_cg_minus_enh" in r]

    summary = {
        "eval_mode": "gc_baseline_aligned_full_pipeline",
        "pairs_file": args.pairs_file,
        "recon_list": args.recon_list,
        "enhanced_root": args.enhanced_root,
        "thresholds_mm": list(thresholds),
        "num_tasks": len(tasks),
        "num_evaluated": len(ok),
        "num_errors": sum(1 for r in records if r.get("error")),
        "means": aggregate_metrics(records, keys),
        "mean_recon_cg_chamfer_distance": float(np.mean(cg_chamfer)) if cg_chamfer else None,
        "mean_enh_chamfer_distance": float(np.mean(enh_chamfer)) if enh_chamfer else None,
        "mean_improvement_recon_cg_minus_enh": float(np.mean(deltas)) if deltas else None,
        "note": (
            "Full Pipeline: recon CG = Stage1 RGBD->CG; ENH = SuperPC on recon CG. "
            "chamfer_distance = (accuracy + completeness) / 2, aligned test vs HE. "
            "Compare ENH to ACMMM26_GC_baseline.csv (official aligned CG) via compare_enh_to_baseline.py."
        ),
        "created_at": datetime.utcnow().isoformat() + "Z",
    }

    out_json = args.out_json
    out_csv = args.out_csv or out_json.replace(".json", ".csv")
    os.makedirs(os.path.dirname(out_json) or ".", exist_ok=True)
    with open(out_json, "w", encoding="utf-8") as f:
        json.dump({"summary": summary, "records": records}, f, indent=2)
    write_csv(out_csv, records, thresholds)

    print(json.dumps(summary, indent=2))
    print(f"Written: {out_json}")
    print(f"Written: {out_csv}")


if __name__ == "__main__":
    main()
