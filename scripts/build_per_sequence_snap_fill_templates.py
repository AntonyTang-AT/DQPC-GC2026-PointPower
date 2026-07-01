#!/usr/bin/env python3
"""Build starter per-sequence snap/fill overrides from grid eval or heuristics."""
from __future__ import annotations

import argparse
import json
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GC2026_ROOT = os.path.dirname(SCRIPT_DIR)

sys.path.insert(0, SCRIPT_DIR)
from enh_refine_config import ROLLBACK_CONFIG, make_snap_fill_preset, resolve_preset  # noqa: E402
from summarize_gc_baseline_by_sequence import summarize_records  # noqa: E402


def best_snap_fill_per_sequence(grid_root: str, eval_name: str) -> dict[str, dict]:
    """Pick lowest per-seq chamfer among pdlts_light_snap*_fill* experiments."""
    candidates: list[tuple[str, dict, dict[str, dict]]] = []
    for name in sorted(os.listdir(grid_root)):
        if not name.startswith("pdlts_light_snap") or "_fill" not in name:
            continue
        ev = os.path.join(grid_root, name, eval_name)
        if not os.path.isfile(ev):
            continue
        with open(ev, encoding="utf-8") as f:
            data = json.load(f)
        per = summarize_records(data.get("records", []))
        cfg_path = os.path.join(grid_root, name, "pipeline_config.json")
        if os.path.isfile(cfg_path):
            with open(cfg_path, encoding="utf-8") as f:
                cfg = json.load(f)
        else:
            cfg = resolve_preset(name).to_dict()
        candidates.append((name, cfg, per))

    if not candidates:
        return {}

    all_seqs = set()
    for _, _, per in candidates:
        all_seqs.update(per.keys())

    out: dict[str, dict] = {}
    for seq in sorted(all_seqs):
        best_name = None
        best_cfg = None
        best_ch = float("inf")
        for name, cfg, per in candidates:
            if seq not in per:
                continue
            ch = float(per[seq]["mean_enh_chamfer_distance"])
            if ch < best_ch:
                best_ch = ch
                best_name = name
                best_cfg = cfg
        if best_cfg:
            out[seq] = {
                "experiment": best_name,
                "mean_enh_chamfer_distance": best_ch,
                **best_cfg,
            }
    return out


def heuristic_templates() -> dict[str, dict]:
    """Before grid completes: higher fill on high-completeness-gap sequences."""
    base = make_snap_fill_preset(1.0, 0.6).to_dict()
    mild = make_snap_fill_preset(1.0, 0.4).to_dict()
    strong = make_snap_fill_preset(1.0, 0.8).to_dict()
    return {
        "TrumanShow": {**strong, "note": "high completeness gap; try fill=0.8"},
        "VirtualLife": {**strong, "note": "high completeness gap; try fill=0.8"},
        "VictoryHeart": {**mild, "note": "near CG; mild fill or cg_passthrough"},
        "default": base,
    }


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--grid-root", default=os.path.join(GC2026_ROOT, "output/enh_refine_snap_fill_grid"))
    p.add_argument(
        "--out-json",
        default=os.path.join(GC2026_ROOT, "output/enh_refine_phase2/per_sequence_snap_fill_overrides.json"),
    )
    p.add_argument("--eval-name", default="evaluation_gc_baseline_val565.json")
    p.add_argument("--heuristic-only", action="store_true")
    args = p.parse_args()

    if args.heuristic_only or not os.path.isdir(args.grid_root):
        per_seq = heuristic_templates()
        source = "heuristic"
    else:
        per_seq = best_snap_fill_per_sequence(args.grid_root, args.eval_name)
        source = "grid_eval" if per_seq else "heuristic"
        if not per_seq:
            per_seq = heuristic_templates()
        else:
            fills = {v.get("fill_mm") for k, v in per_seq.items() if k != "default"}
            exps = {v.get("experiment") for k, v in per_seq.items() if k != "default"}
            if len(fills) <= 1 and len(exps) <= 1:
                per_seq = heuristic_templates()
                source = "heuristic_grid_tied"

    default = make_snap_fill_preset(1.0, 0.6).to_dict()
    sequences = {k: v for k, v in per_seq.items() if k != "default"}
    # Only override snap/fill — keep base geometry cache routing from --preset.
    slim_sequences = {}
    for seq, cfg in sequences.items():
        slim_sequences[seq] = {
            k: cfg[k]
            for k in ("name", "snap_mm", "fill_mm", "post_sor", "post_sor_std", "fill_mode", "bidirectional_snap", "cg_pull_mm")
            if k in cfg
        }
    sequences = slim_sequences
    if "default" in per_seq:
        default = {k: v for k, v in per_seq["default"].items() if k != "note"}

    payload = {
        "source": source,
        "grid_root": args.grid_root,
        "default": default,
        "sequences": sequences,
    }
    os.makedirs(os.path.dirname(args.out_json) or ".", exist_ok=True)
    with open(args.out_json, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)
    print(f"Wrote {args.out_json} ({len(sequences)} sequences, source={source})")
    for seq, cfg in sequences.items():
        print(f"  {seq}: {cfg.get('name')} snap={cfg.get('snap_mm')} fill={cfg.get('fill_mm')}")


if __name__ == "__main__":
    main()
