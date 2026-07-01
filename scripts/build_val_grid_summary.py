#!/usr/bin/env python3
"""Build val grid summary.json from per-experiment GC baseline eval outputs."""
from __future__ import annotations

import argparse
import csv
import json
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GC2026_ROOT = os.path.dirname(SCRIPT_DIR)
DEFAULT_EVAL_NAME = "evaluation_gc_baseline_val565.json"


def load_experiment_row(exp_dir: str, eval_name: str) -> dict | None:
    ev_path = os.path.join(exp_dir, eval_name)
    if not os.path.isfile(ev_path):
        return None
    with open(ev_path, encoding="utf-8") as f:
        data = json.load(f)
    s = data.get("summary", {})
    means = s.get("means", {})
    row = {
        "experiment": os.path.basename(exp_dir),
        "mean_enh_chamfer_distance": means.get("chamfer_distance"),
        "mean_enh_accuracy": means.get("accuracy"),
        "mean_enh_completeness": means.get("completeness"),
        "mean_enh_fscore_10.0": means.get("fscore_10.0"),
        "mean_cg_chamfer_distance": s.get("mean_cg_chamfer_distance"),
        "improvement_cg_minus_enh": s.get("mean_improvement_cg_minus_enh"),
        "num_evaluated": s.get("num_evaluated"),
        "eval_json": ev_path,
    }
    return row


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--grid-root", required=True)
    p.add_argument("--eval-name", default=DEFAULT_EVAL_NAME)
    p.add_argument("--out-json", default=None)
    p.add_argument("--out-csv", default=None)
    args = p.parse_args()

    rows: list[dict] = []
    for name in sorted(os.listdir(args.grid_root)):
        exp_dir = os.path.join(args.grid_root, name)
        if not os.path.isdir(exp_dir):
            continue
        row = load_experiment_row(exp_dir, args.eval_name)
        if row and row["mean_enh_chamfer_distance"] is not None:
            rows.append(row)

    rows.sort(key=lambda r: r["mean_enh_chamfer_distance"])
    out_json = args.out_json or os.path.join(args.grid_root, "summary_official565.json")
    out_csv = args.out_csv or out_json.replace(".json", ".csv")

    with open(out_json, "w", encoding="utf-8") as f:
        json.dump(rows, f, indent=2)
    if rows:
        with open(out_csv, "w", encoding="utf-8", newline="") as f:
            w = csv.DictWriter(f, fieldnames=rows[0].keys())
            w.writeheader()
            w.writerows(rows)
        best = rows[0]
        print(
            f"BEST {best['experiment']}: chamfer={best['mean_enh_chamfer_distance']:.4f} "
            f"improve={best.get('improvement_cg_minus_enh')}"
        )
    print(f"Written {out_json} ({len(rows)} experiments)")


if __name__ == "__main__":
    main()
