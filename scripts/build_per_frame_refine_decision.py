#!/usr/bin/env python3
"""Build per-frame CG rollback oracle + test-time proxy rules from val565 eval."""
from __future__ import annotations

import argparse
import json
import os
import sys
from collections import defaultdict

import numpy as np

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GC2026_ROOT = os.path.dirname(SCRIPT_DIR)
sys.path.insert(0, SCRIPT_DIR)

from enh_refine_pipeline import estimate_cg_inlier_ratio  # noqa: E402
from uvg_io import read_ply_xyz_rgb  # noqa: E402


def load_eval(path: str) -> list[dict]:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    return [r for r in data.get("records", []) if not r.get("error")]


def frame_features(cg_path: str) -> dict:
    xyz, rgb = read_ply_xyz_rgb(cg_path)
    return {
        "n_points": int(xyz.shape[0]),
        "inlier_ratio": estimate_cg_inlier_ratio(xyz, rgb),
    }


def oracle_stats(records: list[dict]) -> dict:
    enh = [float(r["chamfer_distance"]) for r in records]
    cg = [float(r["cg_chamfer_distance"]) for r in records if "cg_chamfer_distance" in r]
    oracle = [
        min(float(r["chamfer_distance"]), float(r["cg_chamfer_distance"]))
        for r in records
        if "cg_chamfer_distance" in r
    ]
    rollback_frames = sum(
        1 for r in records
        if "delta_cg_minus_enh" in r and float(r["delta_cg_minus_enh"]) < 0
    )
    return {
        "num_frames": len(records),
        "mean_enh_chamfer": float(np.mean(enh)) if enh else None,
        "mean_cg_chamfer": float(np.mean(cg)) if cg else None,
        "mean_oracle_chamfer": float(np.mean(oracle)) if oracle else None,
        "oracle_gain_vs_enh": float(np.mean(enh) - np.mean(oracle)) if oracle and enh else None,
        "oracle_gain_vs_cg": float(np.mean(cg) - np.mean(oracle)) if oracle and cg else None,
        "rollback_frame_count": rollback_frames,
        "rollback_frame_ratio": rollback_frames / max(len(records), 1),
    }


def fit_proxy_rules(records: list[dict], features: dict[str, dict]) -> dict:
    """Simple per-sequence inlier-ratio thresholds for passthrough."""
    by_seq: dict[str, list[dict]] = defaultdict(list)
    for r in records:
        if "cg_chamfer_distance" not in r:
            continue
        cg_path = r.get("cg_path", "")
        if not cg_path:
            continue
        feat = features.get(cg_path, {})
        r2 = {**r, **feat}
        by_seq[r.get("sequence", "unknown")].append(r2)

    rules = []
    for seq, rows in sorted(by_seq.items()):
        best_t = None
        best_oracle = float("inf")
        best_stats = None
        for t in np.linspace(0.90, 0.995, 20):
            chosen = []
            for r in rows:
                enh = float(r["chamfer_distance"])
                cg = float(r["cg_chamfer_distance"])
                ir = float(r.get("inlier_ratio", 0.0))
                n_pts = int(r.get("n_points", 0))
                use_cg = ir >= t and n_pts >= 480000
                chosen.append(cg if use_cg else enh)
            mean_ch = float(np.mean(chosen))
            if mean_ch < best_oracle:
                best_oracle = mean_ch
                best_t = float(t)
                n_pass = sum(
                    1 for r in rows
                    if float(r.get("inlier_ratio", 0)) >= t and int(r.get("n_points", 0)) >= 480000
                )
                best_stats = {"passthrough_frames": n_pass, "mean_chamfer": mean_ch}

        if best_t is not None:
            rules.append({
                "sequence": seq,
                "min_inlier_ratio": round(best_t, 4),
                "min_points": 480000,
                "action": "passthrough",
                "val565_mean_chamfer": best_stats["mean_chamfer"] if best_stats else None,
                "val565_passthrough_frames": best_stats["passthrough_frames"] if best_stats else 0,
            })

    # Global fallback: clean CG passthrough
    global_rule = {
        "sequence": "*",
        "min_inlier_ratio": 0.985,
        "min_points": 520000,
        "action": "passthrough",
    }
    return {
        "default_action": "enhance",
        "rules": rules,
        "global_rule": global_rule,
    }


def apply_proxy_to_records(records: list[dict], proxy: dict, features: dict[str, dict]) -> dict:
    chosen = []
    for r in records:
        if "cg_chamfer_distance" not in r:
            continue
        cg_path = r.get("cg_path", "")
        feat = features.get(cg_path, {})
        seq = r.get("sequence", "")
        ir = float(feat.get("inlier_ratio", 0.0))
        n_pts = int(feat.get("n_points", 0))
        use_cg = False
        for rule in proxy.get("rules", []):
            if rule.get("sequence") == seq:
                if ir >= float(rule.get("min_inlier_ratio", 1.0)) and n_pts >= int(rule.get("min_points", 0)):
                    use_cg = True
                break
        gr = proxy.get("global_rule", {})
        if not use_cg and gr:
            if ir >= float(gr.get("min_inlier_ratio", 1.0)) and n_pts >= int(gr.get("min_points", 0)):
                use_cg = True
        enh = float(r["chamfer_distance"])
        cg = float(r["cg_chamfer_distance"])
        chosen.append(cg if use_cg else enh)
    return {
        "mean_proxy_chamfer": float(np.mean(chosen)) if chosen else None,
        "num_frames": len(chosen),
    }


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument(
        "--eval-json",
        default=os.path.join(
            GC2026_ROOT, "output/enh_refine_phase2/pdlts_light_snap1_fill0.6/evaluation_gc_baseline_val565.json",
        ),
    )
    p.add_argument("--out-dir", default=os.path.join(GC2026_ROOT, "output/enh_refine_p0_p1_p2/frame_decision"))
    p.add_argument("--max-samples", type=int, default=0)
    args = p.parse_args()

    records = load_eval(args.eval_json)
    if not records:
        raise SystemExit(f"No records in {args.eval_json}")
    if args.max_samples > 0:
        records = records[: args.max_samples]

    os.makedirs(args.out_dir, exist_ok=True)
    stats = oracle_stats(records)
    print(f"Oracle: enh={stats['mean_enh_chamfer']:.4f} cg={stats['mean_cg_chamfer']:.4f} "
          f"oracle={stats['mean_oracle_chamfer']:.4f} gain={stats['oracle_gain_vs_enh']:.4f}")

    features: dict[str, dict] = {}
    for r in records:
        cg_path = r.get("cg_path", "")
        if not cg_path or not os.path.isfile(cg_path):
            continue
        if cg_path not in features:
            features[cg_path] = frame_features(cg_path)

    proxy = fit_proxy_rules(records, features)
    proxy_eval = apply_proxy_to_records(records, proxy, features)
    print(f"Proxy val565 mean chamfer: {proxy_eval['mean_proxy_chamfer']:.4f}")

    per_frame = {}
    for r in records:
        cg_path = r.get("cg_path", "")
        if not cg_path:
            continue
        delta = r.get("delta_cg_minus_enh")
        per_frame[cg_path] = {
            "frame_id": r.get("frame_id"),
            "sequence": r.get("sequence"),
            "enh_chamfer": r.get("chamfer_distance"),
            "cg_chamfer": r.get("cg_chamfer_distance"),
            "delta_cg_minus_enh": delta,
            "oracle_use_cg": bool(delta is not None and float(delta) < 0),
            **features.get(cg_path, {}),
        }

    with open(os.path.join(args.out_dir, "oracle_analysis.json"), "w", encoding="utf-8") as f:
        json.dump({"stats": stats, "proxy_eval": proxy_eval}, f, indent=2)
    with open(os.path.join(args.out_dir, "proxy_rules.json"), "w", encoding="utf-8") as f:
        json.dump(proxy, f, indent=2)
    with open(os.path.join(args.out_dir, "per_frame_oracle.json"), "w", encoding="utf-8") as f:
        json.dump(per_frame, f, indent=2)
    print(f"Wrote {args.out_dir}")


if __name__ == "__main__":
    main()
