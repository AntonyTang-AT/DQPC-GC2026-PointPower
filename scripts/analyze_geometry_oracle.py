#!/usr/bin/env python3
"""Per-frame oracle: pick best chamfer among light vs heavy PD-LTS + snap/fill."""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from concurrent.futures import ProcessPoolExecutor, as_completed

import numpy as np

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GC2026_ROOT = os.path.dirname(SCRIPT_DIR)
sys.path.insert(0, SCRIPT_DIR)

from enh_refine_config import RefineConfig, make_snap_fill_preset  # noqa: E402
from enh_refine_pipeline import apply_refine_stages, output_ply_path  # noqa: E402
from evaluate_gc_baseline_metrics import eval_aligned_pair, parse_pairs_file  # noqa: E402
from uvg_io import read_ply_xyz_rgb, write_ply_xyz_rgb  # noqa: E402


def refine_from_cache(cg_xyz, cg_rgb, cg_path, cache_dir, model: str, snap: float, fill: float):
    cfg = make_snap_fill_preset(snap, fill)
    cfg.geometry = "from_dir"
    cfg.pdlts_model = model
    cfg.name = f"pdlts_{model}_oracle"
    return apply_refine_stages(
        cg_xyz, cg_rgb, cfg, cg_path=cg_path, geometry_dir=cache_dir,
    )


def _eval_one(payload: dict) -> dict | None:
    try:
        m = eval_aligned_pair(**payload["eval"])
        m["source"] = payload["source"]
        m["frame_id"] = payload["frame_id"]
        m["cg_path"] = payload["cg_path"]
        return m
    except Exception as exc:  # noqa: BLE001
        return {"error": str(exc), "cg_path": payload.get("cg_path"), "source": payload.get("source")}


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument(
        "--pairs-file",
        default=os.path.join(GC2026_ROOT, "data/processed/val_pairs_official_cgv2.txt"),
    )
    p.add_argument("--light-dir", default=os.path.join(GC2026_ROOT, "output/pdlts_val565/light"))
    p.add_argument("--heavy-dir", default=os.path.join(GC2026_ROOT, "output/pdlts_val565/heavy"))
    p.add_argument("--snap-mm", type=float, default=1.0)
    p.add_argument("--fill-mm", type=float, default=0.6)
    p.add_argument("--workers", type=int, default=8)
    p.add_argument("--max-samples", type=int, default=0)
    p.add_argument(
        "--out-json",
        default=os.path.join(GC2026_ROOT, "output/enh_refine_p0_p1_p2/geometry_oracle_light_vs_heavy.json"),
    )
    args = p.parse_args()

    pairs = parse_pairs_file(args.pairs_file)
    if args.max_samples > 0:
        pairs = pairs[: args.max_samples]
    thresholds = (10.0, 20.0, 30.0, 50.0)
    tasks = []
    tmp_files: list[str] = []

    tmp_dir = os.environ.get("TMPDIR") or os.path.join(GC2026_ROOT, "tmp")
    os.makedirs(tmp_dir, exist_ok=True)

    for cg_path, he_path in pairs:
        seq = cg_path.split("/UVG-CWI-DQPC/")[1].split("/")[0] if "/UVG-CWI-DQPC/" in cg_path else ""
        frame_id = os.path.basename(cg_path)
        cg_xyz, cg_rgb = read_ply_xyz_rgb(cg_path)

        for model, cache_dir in (("light", args.light_dir), ("heavy", args.heavy_dir)):
            gpath = output_ply_path(cache_dir, cg_path)
            if not os.path.isfile(gpath):
                continue
            out_xyz, out_rgb, _ = refine_from_cache(
                cg_xyz, cg_rgb, cg_path, cache_dir, model, args.snap_mm, args.fill_mm,
            )
            tmp = tempfile.NamedTemporaryFile(suffix=".ply", delete=False, dir=tmp_dir)
            tmp.close()
            tmp_files.append(tmp.name)
            write_ply_xyz_rgb(tmp.name, out_xyz, out_rgb)
            tasks.append({
                "source": f"{model}_refine",
                "frame_id": frame_id,
                "cg_path": cg_path,
                "eval": {
                    "test_path": tmp.name,
                    "gt_path": he_path,
                    "sequence": seq,
                    "thresholds": thresholds,
                    "max_load_points": 0,
                    "seed": 42,
                },
            })

    results: list[dict] = []
    with ProcessPoolExecutor(max_workers=max(1, args.workers)) as pool:
        futs = [pool.submit(_eval_one, t) for t in tasks]
        for fut in as_completed(futs):
            r = fut.result()
            if r:
                results.append(r)

    for fp in tmp_files:
        try:
            os.remove(fp)
        except OSError:
            pass

    by_frame: dict[str, list[dict]] = {}
    for r in results:
        if r.get("error"):
            continue
        by_frame.setdefault(r["cg_path"], []).append(r)

    oracle_ch = []
    light_ch = []
    heavy_ch = []
    both = 0
    light_wins = heavy_wins = 0
    per_frame = {}

    for cg_path, rows in by_frame.items():
        best = min(rows, key=lambda x: x["chamfer_distance"])
        oracle_ch.append(float(best["chamfer_distance"]))
        per_frame[cg_path] = {
            "best_source": best["source"],
            "best_chamfer": best["chamfer_distance"],
            "candidates": {r["source"]: r["chamfer_distance"] for r in rows},
        }
        for r in rows:
            if r["source"] == "light_refine":
                light_ch.append(float(r["chamfer_distance"]))
            else:
                heavy_ch.append(float(r["chamfer_distance"]))
        if len(rows) >= 2:
            both += 1
            l = next(r for r in rows if r["source"] == "light_refine")
            h = next(r for r in rows if r["source"] == "heavy_refine")
            if l["chamfer_distance"] <= h["chamfer_distance"]:
                light_wins += 1
            else:
                heavy_wins += 1

    summary = {
        "frames_with_any_geometry": len(by_frame),
        "frames_with_both": both,
        "mean_oracle_chamfer": float(np.mean(oracle_ch)) if oracle_ch else None,
        "mean_light_refine_chamfer": float(np.mean(light_ch)) if light_ch else None,
        "mean_heavy_refine_chamfer": float(np.mean(heavy_ch)) if heavy_ch else None,
        "light_wins_on_both": light_wins,
        "heavy_wins_on_both": heavy_wins,
        "snap_mm": args.snap_mm,
        "fill_mm": args.fill_mm,
    }
    os.makedirs(os.path.dirname(args.out_json) or ".", exist_ok=True)
    with open(args.out_json, "w", encoding="utf-8") as f:
        json.dump({"summary": summary, "per_frame": per_frame}, f, indent=2)
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
