#!/usr/bin/env python3
"""Select val grid winner using official GC chamfer_distance (aligned CG/ENH vs HE).

Primary objective: minimize mean ENH chamfer_distance on official val565.
Constraint: mean improvement vs aligned CG baseline >= margin (mm).
"""
from __future__ import annotations

import argparse
import json
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GC2026_ROOT = os.path.dirname(SCRIPT_DIR)
DEFAULT_GRID = os.path.join(GC2026_ROOT, "output", "val_grid_official565")
DEFAULT_EVAL = "evaluation_gc_baseline_val565.json"
GATE_MARGIN_MM = 0.0

sys.path.insert(0, SCRIPT_DIR)
from summarize_gc_baseline_by_sequence import summarize_records  # noqa: E402
from enh_experiment_tag import parse_experiment_tag  # noqa: E402


def load_summary(grid_root: str) -> list[dict]:
    for name in ("summary_official565.json", "summary.json"):
        path = os.path.join(grid_root, name)
        if os.path.isfile(path):
            with open(path, encoding="utf-8") as f:
                return json.load(f)
    return []


def cg_baseline_chamfer(grid_root: str) -> float | None:
    """Reference CG chamfer from first experiment eval or cached baseline file."""
    cache = os.path.join(GC2026_ROOT, "output/baselines/val565_cg_gc_baseline.json")
    if os.path.isfile(cache):
        with open(cache, encoding="utf-8") as f:
            s = json.load(f).get("summary", {})
            v = s.get("mean_cg_chamfer_distance") or s.get("means", {}).get("chamfer_distance")
            if v is not None:
                return float(v)

    rows = load_summary(grid_root)
    for row in rows:
        v = row.get("mean_cg_chamfer_distance")
        if v is not None:
            return float(v)
    return None


def eval_per_sequence(exp_dir: str, eval_name: str) -> dict[str, dict]:
    path = os.path.join(exp_dir, eval_name)
    if not os.path.isfile(path):
        return {}
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    return summarize_records(data.get("records", []))


def score_candidate(row: dict, cg_ref: float | None, args) -> tuple[float, dict]:
    enh = float(row["mean_enh_chamfer_distance"])
    improve = row.get("improvement_cg_minus_enh")
    if improve is None and cg_ref is not None:
        improve = cg_ref - enh
    improve = float(improve) if improve is not None else None

    exp_dir = os.path.join(args.grid_root, row["experiment"])
    val_per = eval_per_sequence(exp_dir, args.eval_name)

    val_seq_positive = sum(
        1 for v in val_per.values() if (v.get("mean_delta_cg_minus_enh") or 0) > 0
    )
    val_seq_total = len(val_per)

    penalty = 0.0
    if improve is not None and improve < args.margin:
        penalty += 1000.0 + (args.margin - improve) * 10.0
    if args.min_seq_positive > 0 and val_seq_total > 0:
        if val_seq_positive < args.min_seq_positive:
            penalty += 500.0 + (args.min_seq_positive - val_seq_positive) * 50.0

    score = enh + penalty
    meta = {
        "improvement_cg_minus_enh": improve,
        "val_sequences_positive": val_seq_positive,
        "val_sequences_total": val_seq_total,
        "penalty": penalty,
    }
    return score, meta


def main() -> None:
    parser = argparse.ArgumentParser(description="Gate selection on official chamfer_distance")
    parser.add_argument("--grid-root", default=DEFAULT_GRID)
    parser.add_argument("--eval-name", default=DEFAULT_EVAL)
    parser.add_argument("--margin", type=float, default=GATE_MARGIN_MM,
                        help="Min mean improvement vs CG baseline (mm, cg-enh)")
    parser.add_argument("--min-seq-positive", type=int, default=1,
                        help="Min val565 sequences with positive per-seq chamfer improvement")
    parser.add_argument("--cg-version", default="v2")
    parser.add_argument("--out-json", default=None)
    args = parser.parse_args()

    rows = load_summary(args.grid_root)
    if not rows:
        raise SystemExit(f"No summary in {args.grid_root} — run run_val_grid_official565.sh first")

    cg_ref = cg_baseline_chamfer(args.grid_root)
    scored = []
    for row in rows:
        score, meta = score_candidate(row, cg_ref, args)
        scored.append((score, row, meta))

    scored.sort(key=lambda x: x[0])
    best_score, best, best_meta = scored[0]

    exp_dir = os.path.join(args.grid_root, best["experiment"])
    val_per = eval_per_sequence(exp_dir, args.eval_name)

    improve = best.get("improvement_cg_minus_enh")
    if improve is None and cg_ref is not None:
        improve = cg_ref - float(best["mean_enh_chamfer_distance"])

    passed = best_meta.get("penalty", 0) == 0.0
    if improve is not None and improve < args.margin:
        passed = False

    out_json = args.out_json or os.path.join(args.grid_root, "gate_decision.json")
    decision = {
        "gate_passed": passed,
        "metric_primary": "chamfer_distance",
        "metric_note": "Official aligned: chamfer = (accuracy + completeness) / 2",
        "margin_required_mm": args.margin,
        "cg_baseline_chamfer_distance": cg_ref,
        "best_experiment": best["experiment"],
        "best_mean_enh_chamfer_distance": best["mean_enh_chamfer_distance"],
        "improvement_cg_minus_enh": improve,
        "best_mean_enh_fscore_10.0": best.get("mean_enh_fscore_10.0"),
        "cg_version": args.cg_version,
        "val_pairs": "data/processed/val_pairs_official_cgv2.txt",
        "gate_constraints": {
            "min_seq_positive": args.min_seq_positive,
        },
        "best_config": parse_experiment_tag(best["experiment"], args.grid_root),
        "per_sequence_val": val_per,
        "selection_meta": best_meta,
        "ranking_top5": [
            {
                "experiment": r["experiment"],
                "chamfer": r["mean_enh_chamfer_distance"],
                "improve": r.get("improvement_cg_minus_enh"),
                "score": s,
            }
            for s, r, _ in scored[:5]
        ],
    }

    with open(out_json, "w", encoding="utf-8") as f:
        json.dump(decision, f, indent=2)

    brief = {k: decision[k] for k in decision if k not in ("per_sequence_val", "ranking_top5")}
    print(json.dumps(brief, indent=2))
    if not passed:
        raise SystemExit(
            f"Gate FAILED: chamfer={best['mean_enh_chamfer_distance']:.4f} "
            f"improve={improve} margin={args.margin}"
        )


if __name__ == "__main__":
    main()
