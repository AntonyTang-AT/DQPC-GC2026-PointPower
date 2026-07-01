#!/usr/bin/env python3
"""
Per-frame: when does latest fusion (frame_gate) beat pure ft PD-LTS?
Identifies frames where SuperPC CG-hole fill helps vs hurts.

Compare:
  fusion = holefill_adaptive_frame_gate  (latest)
  ft     = pdlts_finetune + density refine (no SuperPC)

Writes progress to output/ft_val565_fusion/superpc_fill_analysis/progress.json
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd

SCRIPT_DIR = Path(__file__).resolve().parent
GC2026_ROOT = SCRIPT_DIR.parent
sys.path.insert(0, str(SCRIPT_DIR))

from enh_refine_config import resolve_preset
from enh_refine_pipeline import output_ply_path
from frame_fill_gate import decide_frame_fill_gate
from uvg_io import estimate_primary_fill_add_ratio, read_ply_xyz_rgb

FUSION_EV = GC2026_ROOT / "output/ft_val565_fusion/holefill_adaptive_frame_gate/evaluation_gc_baseline_val565.json"
FT_EV = GC2026_ROOT / "output/pdlts_finetune_uvg/val565_refine/pdlts_light_snap1_fill0.6_density/evaluation_gc_baseline_val565.json"
OUT_DIR = GC2026_ROOT / "output/ft_val565_fusion/superpc_fill_analysis"
PROGRESS_JSON = OUT_DIR / "progress.json"
CSV_OUT = OUT_DIR / "per_frame_fusion_vs_ft.csv"
SUMMARY_JSON = OUT_DIR / "summary.json"
GEOM = GC2026_ROOT / "output/pdlts_finetune_uvg/val565/light"
SEC = GC2026_ROOT / "output/submission_candidate"
TOTAL = 564


def write_progress(done: int, total: int, phase: str, note: str = "") -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    payload = {
        "updated": time.strftime("%Y-%m-%d %H:%M:%S"),
        "phase": phase,
        "done": done,
        "total": total,
        "pct": round(100.0 * done / total, 1) if total else 0,
        "note": note,
    }
    PROGRESS_JSON.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def index_eval(path: Path) -> dict:
    idx = {}
    for r in json.load(open(path, encoding="utf-8"))["records"]:
        if r.get("error"):
            continue
        idx[r["cg_path"]] = r
    return idx


def load_partial() -> dict[str, dict]:
    if not CSV_OUT.is_file():
        return {}
    df = pd.read_csv(CSV_OUT)
    return {row["cg_path"]: row.to_dict() for _, row in df.iterrows()}


def summarize(df: pd.DataFrame) -> dict:
    helps = df[df.d_fusion_ft < 0]
    hurts = df[df.d_fusion_ft > 0]
    oracle_cd = float(df.apply(lambda r: min(r.ft_cd, r.fusion_cd), axis=1).mean())

    by_tier = {}
    for t in ["skip", "lite", "full"]:
        sub = df[df.tier == t]
        if sub.empty:
            continue
        by_tier[t] = {
            "n": int(len(sub)),
            "mean_d_fusion_ft": float(sub.d_fusion_ft.mean()),
            "fusion_wins": int((sub.d_fusion_ft < 0).sum()),
            "mean_est_lite_add": float(sub.est_lite_add.mean()),
        }

    by_seq = {}
    for seq, sub in df.groupby("sequence"):
        by_seq[seq] = {
            "n": int(len(sub)),
            "mean_d_fusion_ft": float(sub.d_fusion_ft.mean()),
            "fusion_wins": int((sub.d_fusion_ft < 0).sum()),
            "mean_est_lite_add": float(sub.est_lite_add.mean()),
        }

    thr_rows = []
    for thr in [0.022, 0.03, 0.04, 0.055, 0.08]:
        use = df.est_lite_add >= thr
        if use.sum() == 0:
            continue
        thr_rows.append({
            "est_lite_add_min": thr,
            "n_use_superpc": int(use.sum()),
            "mean_d_if_fill": float(df.loc[use, "d_fusion_ft"].mean()),
            "fusion_wins": int((df.loc[use, "d_fusion_ft"] < 0).sum()),
            "n_skip": int((~use).sum()),
            "mean_d_if_skip": float(df.loc[~use, "d_fusion_ft"].mean()),
        })

    return {
        "fusion_model": "holefill_adaptive_frame_gate",
        "baseline": "ft_pdlts_density",
        "n_frames": int(len(df)),
        "fusion_cd_mean": float(df.fusion_cd.mean()),
        "ft_cd_mean": float(df.ft_cd.mean()),
        "delta_fusion_minus_ft": float(df.d_fusion_ft.mean()),
        "fusion_wins": int(len(helps)),
        "fusion_hurts": int(len(hurts)),
        "oracle_cd_if_per_frame_best": oracle_cd,
        "by_tier": by_tier,
        "by_sequence": by_seq,
        "threshold_sweep": thr_rows,
        "top_help_frames": helps.nsmallest(15, "d_fusion_ft")[
            ["sequence", "frame_id", "tier", "est_lite_add", "d_fusion_ft", "d_comp", "ft_cd"]
        ].to_dict(orient="records"),
        "recommend_use_superpc": [
            "TrumanShow + est_lite_add >= 5.5% (full tier): sparse blocks ~0070-0080",
            "Completeness gain dominates: d_comp << 0 while d_acc modest",
        ],
        "recommend_skip_superpc": [
            "VictoryHeart: fusion never beats ft on any frame in this run",
            "est_lite_add < 2.2%: SuperPC adds little geometry, post/noise hurts",
            "VirtualLife: mostly hurts unless very high fill ratio",
        ],
    }


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--resume", action="store_true", default=True)
    args = p.parse_args()

    write_progress(0, TOTAL, "init", "loading eval JSONs")
    fusion_idx = index_eval(FUSION_EV)
    ft_idx = index_eval(FT_EV)
    cgs = sorted(set(fusion_idx) & set(ft_idx))
    total = len(cgs)

    partial = load_partial() if args.resume else {}
    extra = resolve_preset("holefill_adaptive_frame_gate").extra
    rows = list(partial.values())
    done_set = set(partial.keys())

    write_progress(len(done_set), total, "features", f"resume {len(done_set)} frames")

    for i, cg in enumerate(cgs):
        if cg in done_set:
            continue
        r_fu, r_ft = fusion_idx[cg], ft_idx[cg]
        cg_xyz, _ = read_ply_xyz_rgb(cg)
        pr_xyz, _ = read_ply_xyz_rgb(output_ply_path(str(GEOM), cg))
        sec_xyz, _ = read_ply_xyz_rgb(output_ply_path(str(SEC), cg))
        tier, metrics = decide_frame_fill_gate(cg_xyz, pr_xyz, extra, sec_xyz)
        est_lite = estimate_primary_fill_add_ratio(
            pr_xyz, sec_xyz, cg_xyz, 0.25, scale_max=1.3, max_fill_ratio=0.10,
        )
        est_full = estimate_primary_fill_add_ratio(
            pr_xyz, sec_xyz, cg_xyz, 0.6, scale_max=2.0, max_fill_ratio=0.15,
        )
        d_fu_ft = float(r_fu["chamfer_distance"]) - float(r_ft["chamfer_distance"])
        row = {
            "cg_path": cg,
            "sequence": r_fu["sequence"],
            "frame_id": r_fu.get("frame_id", ""),
            "tier": tier,
            "est_add_ratio": metrics["frame_fill_gate_est_add_ratio"],
            "est_lite_add": est_lite,
            "est_full_add": est_full,
            "spacing_med": metrics["frame_fill_gate_cg_spacing_med_mm"],
            "spacing_p90": metrics["frame_fill_gate_cg_spacing_p90_mm"],
            "fusion_cd": float(r_fu["chamfer_distance"]),
            "ft_cd": float(r_ft["chamfer_distance"]),
            "d_fusion_ft": d_fu_ft,
            "superpc_helps": d_fu_ft < 0,
            "d_acc": float(r_fu["accuracy"]) - float(r_ft["accuracy"]),
            "d_comp": float(r_fu["completeness"]) - float(r_ft["completeness"]),
            "ft_acc": float(r_ft["accuracy"]),
            "ft_comp": float(r_ft["completeness"]),
            "ft_hole": float(r_ft["completeness"]) - float(r_ft["accuracy"]),
            "cg_cd": float(r_fu.get("cg_chamfer_distance") or 0),
        }
        rows.append(row)
        done_set.add(cg)

        if len(done_set) % 5 == 0 or len(done_set) == total:
            pd.DataFrame(rows).to_csv(CSV_OUT, index=False)
            write_progress(len(done_set), total, "features", f"frame {r_fu.get('frame_id','')}")

    write_progress(total, total, "summary", "writing reports")
    df = pd.DataFrame(rows)
    df.to_csv(CSV_OUT, index=False)
    helps = df[df.superpc_helps].copy()
    helps.sort_values("d_fusion_ft").to_csv(OUT_DIR / "frames_superpc_helps.csv", index=False)
    df[~df.superpc_helps].sort_values("d_fusion_ft", ascending=False).to_csv(
        OUT_DIR / "frames_superpc_hurts.csv", index=False,
    )

    summary = summarize(df)
    SUMMARY_JSON.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    write_progress(total, total, "done", f"fusion_wins={summary['fusion_wins']}/{total}")
    print(json.dumps({k: summary[k] for k in [
        "fusion_cd_mean", "ft_cd_mean", "delta_fusion_minus_ft",
        "fusion_wins", "fusion_hurts", "by_sequence", "by_tier",
    ]}, indent=2))


if __name__ == "__main__":
    main()
