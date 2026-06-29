#!/usr/bin/env python3
"""Export ACMMM26_GC_baseline-compatible CSV from evaluation_gc_baseline JSON."""
from __future__ import annotations

import argparse
import csv
import json
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GC2026_ROOT = os.path.dirname(SCRIPT_DIR)
sys.path.insert(0, SCRIPT_DIR)

from evaluate_gc_baseline_metrics import write_csv  # noqa: E402


def main() -> None:
    p = argparse.ArgumentParser(description="JSON -> gc_baseline CSV")
    p.add_argument("--in-json", required=True)
    p.add_argument("--out-csv", required=True)
    args = p.parse_args()

    with open(args.in_json, "r", encoding="utf-8") as f:
        payload = json.load(f)
    summary = payload.get("summary", {})
    records = payload.get("records", [])
    thresholds = tuple(summary.get("thresholds_mm") or [10.0, 20.0, 30.0, 50.0])

    os.makedirs(os.path.dirname(os.path.abspath(args.out_csv)) or ".", exist_ok=True)
    write_csv(args.out_csv, records, thresholds)

    means = summary.get("means", {})
    print(
        json.dumps(
            {
                "out_csv": args.out_csv,
                "num_records": len([r for r in records if not r.get("error")]),
                "mean_chamfer_distance": means.get("chamfer_distance"),
                "mean_accuracy": means.get("accuracy"),
                "mean_completeness": means.get("completeness"),
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
