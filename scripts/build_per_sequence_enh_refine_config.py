#!/usr/bin/env python3
"""Build per-sequence refine preset from grid eval (pick best chamfer per sequence)."""
from __future__ import annotations

import argparse
import json
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GC2026_ROOT = os.path.dirname(SCRIPT_DIR)
DEFAULT_GRID = os.path.join(GC2026_ROOT, "output", "enh_refine_grid")

sys.path.insert(0, SCRIPT_DIR)
from enh_refine_config import ROLLBACK_CONFIG  # noqa: E402
from summarize_gc_baseline_by_sequence import summarize_records  # noqa: E402


def load_preset_config(exp_dir: str) -> dict:
    p = os.path.join(exp_dir, "pipeline_config.json")
    if os.path.isfile(p):
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    return {"name": os.path.basename(exp_dir)}


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--grid-root", default=DEFAULT_GRID)
    p.add_argument(
        "--out-json",
        default=os.path.join(GC2026_ROOT, "output", "enh_refine_grid", "per_sequence_refine_config.json"),
    )
    p.add_argument("--eval-name", default="evaluation_gc_baseline_val565.json")
    p.add_argument("--default-preset", default="cg_passthrough")
    args = p.parse_args()

    experiments: list[tuple[str, dict, dict[str, dict]]] = []
    for name in sorted(os.listdir(args.grid_root)):
        exp_dir = os.path.join(args.grid_root, name)
        ev = os.path.join(exp_dir, args.eval_name)
        if not os.path.isfile(ev):
            continue
        with open(ev, encoding="utf-8") as f:
            data = json.load(f)
        per_seq = summarize_records(data.get("records", []))
        cfg = load_preset_config(exp_dir)
        experiments.append((name, cfg, per_seq))

    if not experiments:
        raise SystemExit(f"No evaluated experiments under {args.grid_root}")

    all_seqs = set()
    for _, _, per in experiments:
        all_seqs.update(per.keys())

    default_cfg = ROLLBACK_CONFIG.to_dict()
    for _, cfg, _ in experiments:
        if cfg.get("name") == args.default_preset:
            default_cfg = cfg
            break

    out: dict[str, dict] = {}
    for seq in sorted(all_seqs):
        best_name = None
        best_cfg = default_cfg
        best_score = float("-inf")
        for exp_name, cfg, per in experiments:
            if seq not in per:
                continue
            stats = per[seq]
            delta = stats.get("mean_delta_cg_minus_enh")
            if delta is None:
                cg_ch = stats.get("mean_cg_chamfer_distance")
                enh_ch = stats.get("mean_enh_chamfer_distance")
                if cg_ch is not None and enh_ch is not None:
                    delta = float(cg_ch) - float(enh_ch)
            score = float(delta) if delta is not None else -float(stats.get("mean_enh_chamfer_distance", 1e9))
            if score > best_score:
                best_score = score
                best_name = exp_name
                best_cfg = cfg
        out[seq] = {
            "experiment": best_name,
            "mean_delta_cg_minus_enh": best_score if best_score > float("-inf") else None,
            **best_cfg,
        }

    os.makedirs(os.path.dirname(args.out_json) or ".", exist_ok=True)
    with open(args.out_json, "w", encoding="utf-8") as f:
        json.dump({"sequences": out, "default": default_cfg}, f, indent=2)
    print(f"Wrote {args.out_json} ({len(out)} sequences)")


if __name__ == "__main__":
    main()
