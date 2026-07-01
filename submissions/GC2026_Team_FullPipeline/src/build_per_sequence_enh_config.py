#!/usr/bin/env python3
"""Pick per-sequence enhancement config from val_grid experiment evals."""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GC2026_ROOT = os.path.dirname(SCRIPT_DIR)
GRID_ROOT = os.path.join(GC2026_ROOT, "output", "val_grid")

sys.path.insert(0, SCRIPT_DIR)
from summarize_eval_by_sequence import summarize_records as summarize_uvg  # noqa: E402
from summarize_gc_baseline_by_sequence import summarize_records as summarize_gc  # noqa: E402
from enh_experiment_tag import parse_experiment_tag  # noqa: E402

OFFICIAL_EVAL = "evaluation_gc_baseline_val565.json"
LEGACY_EVAL = "evaluation_val_n20k.json"


def load_experiment_eval(exp_dir: str) -> tuple[str, dict[str, dict], str]:
    for ev_name, summarizer, delta_key in (
        (OFFICIAL_EVAL, summarize_gc, "mean_delta_cg_minus_enh"),
        (LEGACY_EVAL, summarize_uvg, "mean_delta_cd_l1"),
    ):
        ev = os.path.join(exp_dir, ev_name)
        if not os.path.isfile(ev):
            continue
        with open(ev, encoding="utf-8") as f:
            data = json.load(f)
        per_seq = summarizer(data.get("records", []))
        return ev_name, per_seq, delta_key
    return "", {}, "mean_delta_cd_l1"


def _cfg_keys(cfg: dict) -> dict:
    keys = ("output_mode", "blend_voxel_mm", "use_vision", "checkpoint")
    out = {k: cfg[k] for k in keys if k in cfg}
    if cfg.get("output_mode") == "fill_cg" and "fill_radius_mm" in cfg:
        out["fill_radius_mm"] = cfg["fill_radius_mm"]
    return out


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--grid-root", default=GRID_ROOT)
    p.add_argument(
        "--out-json",
        default=os.path.join(GC2026_ROOT, "output", "enhancement_eval", "per_sequence_enh_config.json"),
    )
    p.add_argument("--default-experiment", default="", help="Fallback experiment dir name")
    p.add_argument(
        "--full-per-seq-json",
        default=os.path.join(GC2026_ROOT, "output", "enhancement_eval", "per_sequence_submission_full.json"),
        help="Full-dataset per-seq summary to assign model on negative sequences",
    )
    args = p.parse_args()

    experiments: list[tuple[str, dict, dict[str, dict], str]] = []
    for name in sorted(os.listdir(args.grid_root)):
        exp_dir = os.path.join(args.grid_root, name)
        ev_name, per_seq, delta_key = load_experiment_eval(exp_dir)
        if not ev_name:
            continue
        cfg = parse_experiment_tag(name)
        experiments.append((name, cfg, per_seq, delta_key))

    if not experiments:
        raise SystemExit(f"No val grid experiments with evaluation in {args.grid_root}")

    all_seqs = set()
    for _, _, per_seq, _ in experiments:
        all_seqs.update(per_seq.keys())

    default_name = args.default_experiment
    if not default_name:
        def _default_score(item: tuple) -> float:
            name, _, _, dk = item
            ev_name, per_seq, _ = load_experiment_eval(os.path.join(args.grid_root, name))
            if OFFICIAL_EVAL in ev_name:
                with open(os.path.join(args.grid_root, name, ev_name), encoding="utf-8") as f:
                    s = json.load(f)["summary"]
                return float(s.get("mean_enh_chamfer_distance") or s["means"]["chamfer_distance"])
            with open(os.path.join(args.grid_root, name, ev_name), encoding="utf-8") as f:
                return float(json.load(f)["summary"]["mean_enh_cd_l1"])

        default_name = min(experiments, key=_default_score)[0]

    default_cfg = parse_experiment_tag(default_name)
    seq_configs: dict[str, dict] = {}

    for seq in sorted(all_seqs):
        best_delta = None
        best_cfg = None
        for _, cfg, per_seq, delta_key in experiments:
            if seq not in per_seq:
                continue
            d = per_seq[seq].get(delta_key)
            if d is None:
                continue
            if best_delta is None or d > best_delta:
                best_delta = d
                best_cfg = _cfg_keys(cfg)
                best_cfg["mean_delta_val"] = d
                best_cfg["delta_metric"] = delta_key
                best_cfg["source_experiment"] = cfg["experiment"]
        if best_cfg:
            seq_configs[seq] = best_cfg

    if args.full_per_seq_json and os.path.isfile(args.full_per_seq_json):
        with open(args.full_per_seq_json, "r", encoding="utf-8") as f:
            full_data = json.load(f)
        for seq, stats in full_data.get("per_sequence", {}).items():
            delta = float(stats.get("mean_delta_cd_l1", 0.0))
            if seq not in seq_configs and delta > 2.0:
                seq_configs[seq] = {
                    "output_mode": "blend_cg",
                    "blend_voxel_mm": default_cfg["blend_voxel_mm"],
                    "use_vision": default_cfg["use_vision"],
                    "checkpoint": default_cfg["checkpoint"],
                    "mean_delta_cd_l1_full": delta,
                    "source_experiment": default_name,
                }
            elif seq in seq_configs and delta < 0.0:
                seq_configs[seq]["mean_delta_cd_l1_full"] = delta
                seq_configs[seq]["full_negative_note"] = "keep_val_tuned_blend_cg"

    out = {
        "default": {
            **_cfg_keys(default_cfg),
            "source_experiment": default_name,
        },
        "sequences": seq_configs,
        "grid_root": args.grid_root,
        "num_experiments": len(experiments),
    }

    os.makedirs(os.path.dirname(args.out_json) or ".", exist_ok=True)
    with open(args.out_json, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2)
    print(f"Written {args.out_json} ({len(seq_configs)} sequences)")


if __name__ == "__main__":
    main()
