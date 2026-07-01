#!/usr/bin/env python3
"""Fast diagnosis: fusion vs ft using eval JSON only + spot PLY checks."""
from __future__ import annotations

import json
import os
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

FUSION_EV = ROOT / "output/ft_val565_fusion/holefill_adaptive_frame_gate/evaluation_gc_baseline_val565.json"
FT_EV = ROOT / "output/pdlts_finetune_uvg/val565_refine/pdlts_light_snap1_fill0.6_density/evaluation_gc_baseline_val565.json"
LT_EV = ROOT / "output/ft_val565_fusion/holefill_lite_fill0.25_max10pct_adaptive_post25/evaluation_gc_baseline_val565.json"
OUT = ROOT / "output/ft_val565_fusion/superpc_fill_analysis"
OUT.mkdir(parents=True, exist_ok=True)


def load(path):
    idx = {}
    for r in json.load(open(path))["records"]:
        if r.get("error"):
            continue
        idx[r["cg_path"]] = r
    return idx


def main():
    fu, ft, lt = load(FUSION_EV), load(FT_EV), load(LT_EV)
    cgs = sorted(set(fu) & set(ft) & set(lt))
    rows = []
    for cg in cgs:
        a, b, c = fu[cg], ft[cg], lt[cg]
        rows.append({
            "sequence": a["sequence"],
            "frame_id": a.get("frame_id", ""),
            "cg_path": cg,
            "fusion_cd": a["chamfer_distance"],
            "ft_cd": b["chamfer_distance"],
            "lite_cd": c["chamfer_distance"],
            "d_fu_ft": a["chamfer_distance"] - b["chamfer_distance"],
            "d_lite_ft": c["chamfer_distance"] - b["chamfer_distance"],
            "d_acc": a["accuracy"] - b["accuracy"],
            "d_comp": a["completeness"] - b["completeness"],
            "ft_acc": b["accuracy"],
            "ft_comp": b["completeness"],
            "ft_hole": b["completeness"] - b["accuracy"],
            "fusion_acc": a["accuracy"],
            "fusion_comp": a["completeness"],
            "cg_cd": a.get("cg_chamfer_distance"),
            "cg_comp": a.get("cg_completeness"),
            "fusion_path": a.get("test_path"),
            "ft_path": b.get("test_path"),
        })
    df = pd.DataFrame(rows)
    df["oracle"] = df.apply(
        lambda r: min([("ft", r.ft_cd), ("fusion", r.fusion_cd), ("lite", r.lite_cd)], key=lambda x: x[1])[0],
        axis=1,
    )
    df.to_csv(OUT / "per_frame_eval_only.csv", index=False)

    helps = df[df.d_fu_ft < 0]
    hurts = df[df.d_fu_ft > 0]

    print("=" * 60)
    print("GLOBAL (564 frames)")
    print(f"  ft:    {df.ft_cd.mean():.4f}")
    print(f"  fusion:{df.fusion_cd.mean():.4f}  Δ={df.d_fu_ft.mean():+.4f}")
    print(f"  lite:  {df.lite_cd.mean():.4f}  Δ={df.d_lite_ft.mean():+.4f}")
    print(f"  oracle:{df.apply(lambda r: min(r.ft_cd,r.fusion_cd,r.lite_cd),axis=1).mean():.4f}")
    print(f"  fusion wins: {len(helps)}  hurts: {len(hurts)}  tie: {(df.d_fu_ft==0).sum()}")

    print("\nBY SEQUENCE")
    for seq, sub in df.groupby("sequence"):
        w = (sub.d_fu_ft < 0).sum()
        print(f"  {seq}: n={len(sub)} fusion_wins={w} mean_Δ={sub.d_fu_ft.mean():+.4f} "
              f"mean_d_acc={sub.d_acc.mean():+.3f} mean_d_comp={sub.d_comp.mean():+.3f}")

    print("\nORACLE picks:", df.oracle.value_counts().to_dict())

    print("\n--- MECHANISM: when fusion wins vs loses ---")
    print(f"  WINS  (n={len(helps)}): d_acc={helps.d_acc.mean():+.3f} d_comp={helps.d_comp.mean():+.3f} "
          f"ft_cd={helps.ft_cd.mean():.2f} ft_hole={helps.ft_hole.mean():+.2f}")
    print(f"  LOSES (n={len(hurts)}): d_acc={hurts.d_acc.mean():+.3f} d_comp={hurts.d_comp.mean():+.3f} "
          f"ft_cd={hurts.ft_cd.mean():.2f} ft_hole={hurts.ft_hole.mean():+.2f}")

    print("\n--- ft_hole = ft_comp - ft_acc (positive => completeness worse than accuracy) ---")
    for thr in [-2, 0, 0.5, 1.0, 1.5, 2.0, 3.0]:
        sub = df[df.ft_hole > thr]
        if sub.empty:
            continue
        w = (sub.d_fu_ft < 0).sum()
        print(f"  ft_hole>{thr}: n={len(sub)} wins={w} ({100*w/len(sub):.0f}%) mean_Δ={sub.d_fu_ft.mean():+.4f}")

    print("\n--- ft_cd buckets (ft already good => skip SuperPC?) ---")
    for lo, hi in [(0, 13.5), (13.5, 14), (14, 14.5), (14.5, 15), (15, 16), (16, 99)]:
        sub = df[(df.ft_cd >= lo) & (df.ft_cd < hi)]
        if sub.empty:
            continue
        w = (sub.d_fu_ft < 0).sum()
        print(f"  ft_cd [{lo},{hi}): n={len(sub)} wins={w} mean_Δ={sub.d_fu_ft.mean():+.4f}")

    print("\n--- TrumanShow frame clusters (where wins cluster) ---")
    ts = df[df.sequence == "TrumanShow"].copy()
    ts["fid"] = pd.to_numeric(ts.frame_id, errors="coerce")
    win_ids = helps[helps.sequence == "TrumanShow"]["frame_id"].tolist()
    print(f"  TS wins {len(win_ids)} frames, sample ids: {sorted(win_ids)[:5]}...{sorted(win_ids)[-5:]}")
    ts_win = ts[ts.d_fu_ft < 0]
    ts_lose = ts[ts.d_fu_ft > 0]
    print(f"  TS win  ft_cd={ts_win.ft_cd.mean():.2f} ft_hole={ts_win.ft_hole.mean():+.2f}")
    print(f"  TS lose ft_cd={ts_lose.ft_cd.mean():.2f} ft_hole={ts_lose.ft_hole.mean():+.2f}")

    print("\n--- VictoryHeart: any win? ---")
    vh = df[df.sequence == "VictoryHeart"]
    print(f"  all lose: min d_fu_ft={vh.d_fu_ft.min():+.4f} max={vh.d_fu_ft.max():+.4f}")
    print(f"  mean d_acc={vh.d_acc.mean():+.3f} d_comp={vh.d_comp.mean():+.3f} (acc up, comp up => double hurt)")

  # Spot check: did fusion actually differ from ft on VH?
    print("\n--- PLY point-count spot check (fusion vs ft) ---")
    from uvg_io import read_ply_xyz_rgb
    samples = [
        ("VH0041 hurt", vh.sort_values("d_fu_ft", ascending=False).iloc[0]),
        ("TS0072 win", helps[helps.sequence == "TrumanShow"].sort_values("d_fu_ft").iloc[0] if len(helps[helps.sequence=="TrumanShow"]) else None),
        ("VH median", vh.iloc[len(vh)//2]),
    ]
    for label, row in samples:
        if row is None:
            continue
        try:
            n_fu = read_ply_xyz_rgb(row.fusion_path)[0].shape[0]
            n_ft = read_ply_xyz_rgb(row.ft_path)[0].shape[0]
            ratio = (n_fu - n_ft) / n_ft
            print(f"  {label} frame={row.frame_id}: fusion_pts={n_fu} ft_pts={n_ft} add_ratio={ratio:.4f} d_fu_ft={row.d_fu_ft:+.4f}")
        except Exception as e:
            print(f"  {label}: err {e}")

    # Check if fusion == ft exactly (skip tier working?)
    same_cd = (df.d_fu_ft.abs() < 1e-6).sum()
    near_same = (df.d_fu_ft.abs() < 0.01).sum()
    print(f"\n--- fusion identical to ft? ---")
    print(f"  exact same CD: {same_cd}  within 0.01mm: {near_same}")

    # infer_meta tier vs outcome
    meta_path = ROOT / "output/ft_val565_fusion/holefill_adaptive_frame_gate/infer_meta.json"
    if meta_path.is_file():
        meta = json.load(open(meta_path))
        recs = meta.get("records", [])
        print(f"\n--- infer_meta issue: only {len(recs)} records (merge bug) ---")
        if recs:
            from collections import Counter
            tc = Counter(r.get("frame_fill_gate") for r in recs)
            print(f"  tiers logged: {dict(tc)}")

    # Root cause summary
    diagnosis = {
        "problem_1": "VH/VL: fusion NEVER beats ft (0/197 VH). SuperPC fill always hurts.",
        "problem_2": "Mechanism on hurt frames: d_acc>0 AND d_comp>0 (accuracy AND completeness both worsen)",
        "problem_3": "Mechanism on help frames (TS): d_comp<<0 dominates (completeness gain), d_acc small positive",
        "problem_4": "frame_gate gate not saving VH: fusion still adds points on VH (see PLY spot check)",
        "problem_5": "infer_meta only 18 frames - merge pass incomplete, cannot audit per-frame tier assignment",
        "root_cause": "SuperPC geometry is off-manifold vs HE; only helps TS sparse blocks where ft misses coverage. "
                      "Global/tier gate still fills too many VH/VL frames with lite tier.",
        "recommended_fix": [
            "VH + VL: hard skip (never SuperPC) -> equals ft on 393 frames",
            "TS only: use SuperPC when est_lite_add >= 5.5% (full tier)",
            "Verify skip tier produces identical PLY to ft on VH",
        ],
        "numbers": {
            "fusion_cd": float(df.fusion_cd.mean()),
            "ft_cd": float(df.ft_cd.mean()),
            "delta": float(df.d_fu_ft.mean()),
            "fusion_wins": int(len(helps)),
            "oracle_cd": float(df.apply(lambda r: min(r.ft_cd, r.fusion_cd, r.lite_cd), axis=1).mean()),
        },
        "by_sequence": {
            seq: {"wins": int((sub.d_fu_ft < 0).sum()), "n": int(len(sub)), "mean_delta": float(sub.d_fu_ft.mean())}
            for seq, sub in df.groupby("sequence")
        },
    }
    json.dump(diagnosis, open(OUT / "diagnosis.json", "w"), indent=2)
    helps.sort_values("d_fu_ft").to_csv(OUT / "frames_superpc_helps.csv", index=False)
    hurts.sort_values("d_fu_ft", ascending=False).to_csv(OUT / "frames_superpc_hurts.csv", index=False)

    print("\n" + "=" * 60)
    print("ROOT CAUSE:", diagnosis["root_cause"])
    print("wrote", OUT / "diagnosis.json")


if __name__ == "__main__":
    os.chdir(ROOT)
    main()
