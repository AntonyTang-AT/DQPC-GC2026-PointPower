#!/usr/bin/env python3
"""Per-sequence summary from evaluate_gc_baseline_metrics JSON."""
from __future__ import annotations

import argparse
import json
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GC2026_ROOT = os.path.dirname(SCRIPT_DIR)


def summarize_records(records: list[dict]) -> dict[str, dict]:
    by_seq: dict[str, list[dict]] = {}
    for r in records:
        if r.get("error"):
            continue
        seq = r.get("sequence") or "unknown"
        by_seq.setdefault(seq, []).append(r)

    out: dict[str, dict] = {}
    for seq, rows in sorted(by_seq.items()):
        n = len(rows)
        mean_enh = sum(float(r["chamfer_distance"]) for r in rows) / n
        cg_vals = [float(r["cg_chamfer_distance"]) for r in rows if "cg_chamfer_distance" in r]
        mean_cg = sum(cg_vals) / len(cg_vals) if cg_vals else None
        out[seq] = {
            "num_frames": n,
            "mean_enh_chamfer_distance": mean_enh,
            "mean_cg_chamfer_distance": mean_cg,
            "mean_delta_cg_minus_enh": (mean_cg - mean_enh) if mean_cg is not None else None,
            "mean_accuracy": sum(float(r["accuracy"]) for r in rows) / n,
            "mean_completeness": sum(float(r["completeness"]) for r in rows) / n,
            "mean_fscore_10.0": sum(float(r.get("fscore_10.0", 0.0)) for r in rows) / n,
        }
    return out


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--eval-json", required=True)
    p.add_argument("--out-json", default=None)
    args = p.parse_args()

    with open(args.eval_json, encoding="utf-8") as f:
        data = json.load(f)
    records = data.get("records", [])
    per_seq = summarize_records(records)
    deltas = [v["mean_delta_cg_minus_enh"] for v in per_seq.values() if v["mean_delta_cg_minus_enh"] is not None]

    summary = {
        "source_eval": os.path.abspath(args.eval_json),
        "metric": "chamfer_distance",
        "num_sequences": len(per_seq),
        "num_evaluated": data.get("summary", {}).get("num_evaluated", len(records)),
        "mean_enh_chamfer_distance": data.get("summary", {}).get("means", {}).get("chamfer_distance"),
        "mean_cg_chamfer_distance": data.get("summary", {}).get("mean_cg_chamfer_distance"),
        "mean_improvement_cg_minus_enh": data.get("summary", {}).get("mean_improvement_cg_minus_enh"),
        "sequences_positive": sum(1 for d in deltas if d > 0),
        "sequences_negative": sum(1 for d in deltas if d <= 0),
        "per_sequence": per_seq,
    }

    out_path = args.out_json or args.eval_json.replace(".json", "_per_sequence.json")
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)
    print(f"Written {out_path} ({len(per_seq)} sequences)")


if __name__ == "__main__":
    main()
