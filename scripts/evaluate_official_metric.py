#!/usr/bin/env python3
"""Evaluate ENH vs HE using UVG-CWI official Metric repo (code/Metric/metrics.py).

Official ``eval_type='ply'`` loads ALL points and OOMs on dense HE (~2M pts/frame).
This wrapper subsamples pred/gt to ``--max-points`` (default 20000) then applies the
same chamfer-L1 / F-score logic as ``metrics.eval_pointcloud``.

Metric naming:
  official chamfer-L1 = CD_Acc + CD_Comp
  local evaluate_uvg cd_l1 ≈ 0.5 * (Acc + Comp) = official chamferL2_old
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime

import numpy as np
from tqdm import tqdm

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GC2026_ROOT = os.path.dirname(SCRIPT_DIR)
METRIC_ROOT = os.path.join(GC2026_ROOT, "code", "Metric")
sys.path.insert(0, SCRIPT_DIR)
sys.path.insert(0, METRIC_ROOT)

from metrics import chamfer_L1, distance_p2p, get_threshold_percentage  # noqa: E402
from evaluate_uvg import enh_path_from_cg, subsample_xyz  # noqa: E402
from uvg_io import cg_to_he_path, parse_frame_id, read_ply_xyz  # noqa: E402


def eval_frame_official(
    pred_xyz: np.ndarray,
    gt_xyz: np.ndarray,
    thresholds: list[int],
    rng: np.random.RandomState,
    max_points: int,
) -> dict:
    pred = subsample_xyz(pred_xyz.astype(np.float64), max_points, rng)
    gt = subsample_xyz(gt_xyz.astype(np.float64), max_points, rng)

    completeness, _ = distance_p2p(gt, None, pred, None)
    recall = get_threshold_percentage(completeness, thresholds)
    completeness_mean = float(completeness.mean())

    accuracy, _ = distance_p2p(pred, None, gt, None)
    precision = get_threshold_percentage(accuracy, thresholds)
    accuracy_mean = float(accuracy.mean())

    chamfer_l1 = float(chamfer_L1(pred, gt))
    chamfer_l2_old = 0.5 * (completeness_mean + accuracy_mean)

    out = {
        "CD_Acc": accuracy_mean,
        "CD_Comp": completeness_mean,
        "chamfer-L1": chamfer_l1,
        "chamferL2_old": chamfer_l2_old,
        "n_pred": int(pred_xyz.shape[0]),
        "n_gt": int(gt_xyz.shape[0]),
        "n_sampled": int(max_points),
    }
    for i, tau in enumerate(thresholds):
        p, r = precision[i], recall[i]
        f = 0.0 if (p + r == 0) else 2 * p * r / (p + r)
        out[f"P_{tau}"] = float(p)
        out[f"R_{tau}"] = float(r)
        out[f"F_{tau}"] = float(f)
    return out


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Official Metric wrapper (subsampled)")
    p.add_argument(
        "--pairs-file",
        default=os.path.join(GC2026_ROOT, "data/processed/val_pairs_official_cgv2.txt"),
    )
    p.add_argument("--enhanced-root", required=True)
    p.add_argument("--max-points", type=int, default=20000, help="Subsample cap per cloud")
    p.add_argument("--max-load-points", type=int, default=500000, help="Cap when reading PLY (0=all)")
    p.add_argument("--max-frames", type=int, default=0, help="Limit frames (0=all)")
    p.add_argument("--thresholds", default="5,10,20")
    p.add_argument("--seed", type=int, default=21)
    p.add_argument("--out-json", default=None)
    p.add_argument("--also-cg", action="store_true", help="Also score official CG baseline")
    return p.parse_args()


def main() -> None:
    args = parse_args()
    thresholds = [int(x) for x in args.thresholds.split(",") if x.strip()]
    rng = np.random.RandomState(args.seed)
    max_load = args.max_load_points if args.max_load_points > 0 else 0

    with open(args.pairs_file, encoding="utf-8") as f:
        lines = [ln.strip() for ln in f if ln.strip() and not ln.startswith("#")]
    if args.max_frames > 0:
        lines = lines[: args.max_frames]

    records = []
    enh_l1, cg_l1 = [], []

    for line in tqdm(lines, desc="official_metric"):
        parts = line.split("\t")
        cg_path = parts[0]
        he_path = parts[1] if len(parts) > 1 and parts[1] else cg_to_he_path(cg_path)
        enh_path = enh_path_from_cg(cg_path, args.enhanced_root)
        if not os.path.isfile(he_path) or not os.path.isfile(enh_path):
            continue

        he_xyz = read_ply_xyz(he_path, max_points=max_load, rng=rng)
        enh_xyz = read_ply_xyz(enh_path, max_points=max_load, rng=rng)
        frame_rng = np.random.RandomState(args.seed + len(records))
        m_enh = eval_frame_official(enh_xyz, he_xyz, thresholds, frame_rng, args.max_points)
        enh_l1.append(m_enh["chamfer-L1"])

        rec = {
            "frame_id": parse_frame_id(cg_path),
            "enh_path": enh_path,
            "he_path": he_path,
            **{k: v for k, v in m_enh.items() if k.startswith(("CD_", "chamfer", "F_", "P_", "R_", "n_"))},
        }

        if args.also_cg and os.path.isfile(cg_path):
            cg_xyz = read_ply_xyz(cg_path, max_points=max_load, rng=rng)
            m_cg = eval_frame_official(cg_xyz, he_xyz, thresholds, frame_rng, args.max_points)
            rec["cg_chamfer-L1"] = m_cg["chamfer-L1"]
            rec["delta_cg_minus_enh"] = m_cg["chamfer-L1"] - m_enh["chamfer-L1"]
            cg_l1.append(m_cg["chamfer-L1"])

        records.append(rec)

    summary = {
        "metric_repo": METRIC_ROOT,
        "eval_mode": "subsampled_official_metrics",
        "pairs_file": args.pairs_file,
        "enhanced_root": args.enhanced_root,
        "max_points": args.max_points,
        "thresholds_mm": thresholds,
        "num_evaluated": len(records),
        "mean_enh_chamfer-L1": float(np.mean(enh_l1)) if enh_l1 else None,
        "note": "chamfer-L1 = Acc+Comp (official); compare evaluate_uvg cd_l1 ≈ chamferL2_old",
        "created_at": datetime.utcnow().isoformat() + "Z",
    }
    if cg_l1:
        summary["mean_cg_chamfer-L1"] = float(np.mean(cg_l1))
        summary["mean_improvement_cg_minus_enh"] = float(np.mean(cg_l1) - np.mean(enh_l1))

    out = args.out_json or os.path.join(args.enhanced_root, "evaluation_official_metric.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump({"summary": summary, "records": records}, f, indent=2)

    print(json.dumps(summary, indent=2))
    print(f"Written: {out}")


if __name__ == "__main__":
    main()
