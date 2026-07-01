#!/usr/bin/env python3
"""Benchmark rule-based adaptive snap vs fixed snap / vh_snap0 oracle."""
from __future__ import annotations

import argparse
import copy
import json
import os
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GC2026_ROOT = os.path.dirname(SCRIPT_DIR)
sys.path.insert(0, SCRIPT_DIR)

from enh_refine_config import RefineConfig, resolve_preset  # noqa: E402


def make_adaptive_cfg(base_name: str, rule: str, param: float) -> RefineConfig:
    cfg = resolve_preset(base_name)
    d = cfg.to_dict()
    extra = dict(d.get("extra") or {})
    extra["adaptive_snap"] = True
    extra["adaptive_snap_rule"] = rule
    if rule == "inlier":
        extra["adaptive_snap_inlier_min"] = param
        tag = f"inlier{param:.3f}".replace(".", "p")
    else:
        extra["adaptive_snap_geom_median_mm"] = param
        tag = f"geom{param:.2f}".replace(".", "p")
    d["extra"] = extra
    d["name"] = f"{base_name}_adapt_snap_{tag}"
    return RefineConfig.from_dict(d)


def run_one(
    cfg: RefineConfig,
    cg_list: str,
    geometry_dir: str,
    out_root: str,
    pairs_file: str,
    workers: int,
) -> dict:
    out_dir = os.path.join(out_root, cfg.tag())
    cfg_path = os.path.join(out_dir, "_config.json")
    os.makedirs(out_dir, exist_ok=True)
    with open(cfg_path, "w", encoding="utf-8") as f:
        json.dump(cfg.to_dict(), f, indent=2)

    infer = [
        sys.executable,
        os.path.join(SCRIPT_DIR, "run_enh_refine_infer.py"),
        "--cg-list",
        cg_list,
        "--out-dir",
        out_dir,
        "--config-json",
        cfg_path,
        "--geometry-dir",
        geometry_dir,
        "--use-geometry-cache",
        "--require-geometry-cache",
    ]
    subprocess.check_call(infer)

    eval_json = os.path.join(out_dir, "evaluation_gc_baseline.json")
    ev = [
        sys.executable,
        os.path.join(SCRIPT_DIR, "evaluate_gc_baseline_metrics.py"),
        "--pairs-file",
        pairs_file,
        "--test-root",
        out_dir,
        "--test-mode",
        "enh",
        "--workers",
        str(workers),
        "--also-cg",
        "--out-json",
        eval_json,
    ]
    subprocess.check_call(ev)
    summary = json.load(open(eval_json, encoding="utf-8"))["summary"]
    return {
        "name": cfg.name,
        "out_dir": out_dir,
        "mean_chamfer_distance": summary["means"]["chamfer_distance"],
        "mean_improvement_cg_minus_enh": summary.get("mean_improvement_cg_minus_enh"),
        "num_evaluated": summary.get("num_evaluated"),
    }


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--cg-list", required=True)
    p.add_argument("--pairs-file", required=True)
    p.add_argument("--geometry-dir", required=True)
    p.add_argument("--out-root", default=os.path.join(GC2026_ROOT, "output", "adaptive_snap_study"))
    p.add_argument("--base-preset", default="pdlts_light_snap1_fill0.6_density")
    p.add_argument("--workers", type=int, default=16)
    p.add_argument("--skip-sweep", action="store_true", help="Only run baseline density")
    p.add_argument(
        "--skip-baseline-infer",
        action="store_true",
        help="Reuse existing eval JSON instead of re-running base preset",
    )
    p.add_argument("--baseline-eval-json", default="")
    args = p.parse_args()

    os.makedirs(args.out_root, exist_ok=True)
    results = []

    if args.skip_baseline_infer and args.baseline_eval_json:
        summary = json.load(open(args.baseline_eval_json, encoding="utf-8"))["summary"]
        results.append(
            {
                "name": args.base_preset,
                "out_dir": os.path.dirname(os.path.abspath(args.baseline_eval_json)),
                "mean_chamfer_distance": summary["means"]["chamfer_distance"],
                "mean_improvement_cg_minus_enh": summary.get("mean_improvement_cg_minus_enh"),
                "num_evaluated": summary.get("num_evaluated"),
                "reused_eval": True,
            }
        )
    else:
        base = resolve_preset(args.base_preset)
        results.append(
            run_one(base, args.cg_list, args.geometry_dir, args.out_root, args.pairs_file, args.workers)
        )

    if not args.skip_sweep:
        for thresh in (0.970, 0.975, 0.980):
            cfg = make_adaptive_cfg(args.base_preset, "inlier", thresh)
            results.append(
                run_one(cfg, args.cg_list, args.geometry_dir, args.out_root, args.pairs_file, args.workers)
            )
        for thresh in (0.7, 0.9):
            cfg = make_adaptive_cfg(args.base_preset, "geometry_close", thresh)
            results.append(
                run_one(cfg, args.cg_list, args.geometry_dir, args.out_root, args.pairs_file, args.workers)
            )

    results.sort(key=lambda r: r["mean_chamfer_distance"])
    report = {
        "cg_list": os.path.abspath(args.cg_list),
        "pairs_file": os.path.abspath(args.pairs_file),
        "geometry_dir": os.path.abspath(args.geometry_dir),
        "results": results,
        "best": results[0],
    }
    out_path = os.path.join(args.out_root, "benchmark_report.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)
    print(f"Wrote {out_path}")
    print("name                                          chamfer   improve")
    for r in results:
        print(
            f"{r['name'][:44]:44s} {r['mean_chamfer_distance']:8.4f} "
            f"{r.get('mean_improvement_cg_minus_enh', 0):+8.4f}"
        )


if __name__ == "__main__":
    main()
