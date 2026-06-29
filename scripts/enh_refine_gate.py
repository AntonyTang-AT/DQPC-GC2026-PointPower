#!/usr/bin/env python3
"""Select best Enh refine preset on val565; rollback to CG passthrough if none beat baseline."""
from __future__ import annotations

import argparse
import json
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GC2026_ROOT = os.path.dirname(SCRIPT_DIR)
DEFAULT_GRID = os.path.join(GC2026_ROOT, "output", "enh_refine_grid")

sys.path.insert(0, SCRIPT_DIR)
from enh_refine_config import ROLLBACK_CONFIG, RefineConfig  # noqa: E402
from summarize_gc_baseline_by_sequence import summarize_records  # noqa: E402


def load_summary(grid_root: str) -> list[dict]:
    path = os.path.join(grid_root, "summary_val565.json")
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    return []


def cg_baseline_chamfer() -> float | None:
    cache = os.path.join(GC2026_ROOT, "output/baselines/val565_cg_gc_baseline.json")
    if os.path.isfile(cache):
        with open(cache, encoding="utf-8") as f:
            s = json.load(f).get("summary", {})
            v = s.get("mean_cg_chamfer_distance") or s.get("means", {}).get("chamfer_distance")
            if v is not None:
                return float(v)
    return None


def load_preset_config(exp_dir: str) -> dict:
    p = os.path.join(exp_dir, "pipeline_config.json")
    if os.path.isfile(p):
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    tag = os.path.basename(exp_dir)
    return {"name": tag, "geometry": "unknown", "tag": tag}


def main() -> None:
    p = argparse.ArgumentParser(description="Enh refine grid gate with rollback")
    p.add_argument("--grid-root", default=DEFAULT_GRID)
    p.add_argument("--margin", type=float, default=0.0, help="Min improvement vs CG baseline (mm)")
    p.add_argument("--eval-name", default="evaluation_gc_baseline_val565.json")
    p.add_argument("--out-json", default="")
    args = p.parse_args()

    rows = load_summary(args.grid_root)
    if not rows:
        raise SystemExit(f"No summary in {args.grid_root} — run run_enh_refine_val565_grid.sh")

    cg_ref = cg_baseline_chamfer()
    scored = []
    for row in rows:
        enh = float(row["mean_enh_chamfer_distance"])
        improve = row.get("improvement_cg_minus_enh")
        if improve is None and cg_ref is not None:
            improve = cg_ref - enh
        improve = float(improve) if improve is not None else None
        penalty = 0.0
        if improve is not None and improve < args.margin:
            penalty += 1000.0 + (args.margin - improve) * 10.0
        scored.append((enh + penalty, row, improve, penalty))

    scored.sort(key=lambda x: x[0])
    _, best_row, best_improve, penalty = scored[0]
    beat_baseline = penalty == 0.0 and (best_improve is None or best_improve >= args.margin)

    exp_dir = os.path.join(args.grid_root, best_row["experiment"])
    eval_path = os.path.join(exp_dir, args.eval_name)
    val_per = {}
    if os.path.isfile(eval_path):
        with open(eval_path, encoding="utf-8") as f:
            val_per = summarize_records(json.load(f).get("records", []))

    winner_cfg = load_preset_config(exp_dir)
    production = winner_cfg if beat_baseline else ROLLBACK_CONFIG.to_dict()

    decision = {
        "gate_passed": beat_baseline,
        "metric_primary": "chamfer_distance",
        "margin_required_mm": args.margin,
        "cg_baseline_chamfer_distance": cg_ref,
        "best_experiment": best_row["experiment"],
        "best_mean_enh_chamfer_distance": best_row["mean_enh_chamfer_distance"],
        "improvement_cg_minus_enh": best_improve,
        "best_config": winner_cfg,
        "production_config": production,
        "rollback_config": ROLLBACK_CONFIG.to_dict(),
        "rollback_note": (
            "If production worse than CG baseline, use --preset cg_passthrough or "
            "apply_enh_refine_decision.py --rollback-only"
        ),
        "per_sequence_val": val_per,
        "ranking_top5": [
            {
                "experiment": r["experiment"],
                "chamfer": r["mean_enh_chamfer_distance"],
                "improve": imp,
            }
            for _, r, imp, _ in scored[:5]
        ],
    }

    out_json = args.out_json or os.path.join(args.grid_root, "gate_decision.json")
    with open(out_json, "w", encoding="utf-8") as f:
        json.dump(decision, f, indent=2)

    print(json.dumps({k: v for k, v in decision.items() if k != "per_sequence_val"}, indent=2))
    if beat_baseline:
        print(f"[gate] PASS -> production={production.get('name')}")
    else:
        print(f"[gate] ROLLBACK -> cg_passthrough (best={best_row['experiment']} "
              f"chamfer={best_row['mean_enh_chamfer_distance']:.4f})")


if __name__ == "__main__":
    main()
