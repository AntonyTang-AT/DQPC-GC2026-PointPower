#!/usr/bin/env python3
"""Find when SuperPC hybrid beats pure ft PD-LTS on val565."""
from __future__ import annotations

import json
import os
import sys
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

FG_EV = GC2026_ROOT / "output/ft_val565_fusion/holefill_adaptive_frame_gate/evaluation_gc_baseline_val565.json"
FT_EV = GC2026_ROOT / "output/pdlts_finetune_uvg/val565_refine/pdlts_light_snap1_fill0.6_density/evaluation_gc_baseline_val565.json"
LT_EV = GC2026_ROOT / "output/ft_val565_fusion/holefill_lite_fill0.25_max10pct_adaptive_post25/evaluation_gc_baseline_val565.json"
OUT_DIR = GC2026_ROOT / "output/ft_val565_fusion/holefill_adaptive_frame_gate"
GEOM = GC2026_ROOT / "output/pdlts_finetune_uvg/val565/light"
SEC = GC2026_ROOT / "output/submission_candidate"


def index_eval(path: Path) -> dict:
    idx = {}
    for r in json.load(open(path, encoding="utf-8"))["records"]:
        if r.get("error"):
            continue
        idx[r["cg_path"]] = r
    return idx


def report(sub: pd.DataFrame, name: str) -> None:
    if sub.empty:
        return
    print(f"\n=== {name} n={len(sub)} ===")
    print(f"  mean d_fg_ft: {sub.d_fg_ft.mean():+.4f}  wins={(sub.d_fg_ft < 0).sum()}")
    print(f"  mean d_acc/d_comp: {sub.d_acc.mean():+.3f} / {sub.d_comp.mean():+.3f}")
    print(f"  mean ft_cd: {sub.ft_cd.mean():.3f}  ft_hole(comp-acc): {sub.ft_hole.mean():+.3f}")
    print(f"  mean est_lite_add: {sub.est_lite_add.mean():.4f}")


def main() -> None:
    extra = resolve_preset("holefill_adaptive_frame_gate").extra
    fg_idx = index_eval(FG_EV)
    ft_idx = index_eval(FT_EV)
    lt_idx = index_eval(LT_EV)
    cgs = sorted(set(fg_idx) & set(ft_idx) & set(lt_idx))
    print(f"frames {len(cgs)}")

    rows = []
    for i, cg in enumerate(cgs):
        r_fg, r_ft, r_lt = fg_idx[cg], ft_idx[cg], lt_idx[cg]
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
        n_fg = n_ft = None
        try:
            if os.path.isfile(r_fg["test_path"]):
                n_fg = read_ply_xyz_rgb(r_fg["test_path"])[0].shape[0]
            if os.path.isfile(r_ft["test_path"]):
                n_ft = read_ply_xyz_rgb(r_ft["test_path"])[0].shape[0]
        except Exception:
            pass
        actual_add = (n_fg - n_ft) / n_ft if n_fg and n_ft else np.nan

        rows.append({
            "sequence": r_fg["sequence"],
            "frame_id": r_fg.get("frame_id", ""),
            "tier": tier,
            "est_add_ratio": metrics["frame_fill_gate_est_add_ratio"],
            "est_lite_add": est_lite,
            "est_full_add": est_full,
            "actual_add_ratio": actual_add,
            "spacing_med": metrics["frame_fill_gate_cg_spacing_med_mm"],
            "spacing_p90": metrics["frame_fill_gate_cg_spacing_p90_mm"],
            "fg_cd": r_fg["chamfer_distance"],
            "ft_cd": r_ft["chamfer_distance"],
            "lt_cd": r_lt["chamfer_distance"],
            "d_fg_ft": r_fg["chamfer_distance"] - r_ft["chamfer_distance"],
            "d_lt_ft": r_lt["chamfer_distance"] - r_ft["chamfer_distance"],
            "d_acc": r_fg["accuracy"] - r_ft["accuracy"],
            "d_comp": r_fg["completeness"] - r_ft["completeness"],
            "ft_acc": r_ft["accuracy"],
            "ft_comp": r_ft["completeness"],
            "ft_hole": r_ft["completeness"] - r_ft["accuracy"],
            "cg_cd": r_fg.get("cg_chamfer_distance"),
            "cg_comp": r_fg.get("cg_completeness"),
            "cg_acc": r_fg.get("cg_accuracy"),
        })
        if (i + 1) % 100 == 0:
            print(f"  {i + 1}/{len(cgs)}")

    df = pd.DataFrame(rows)
    df.to_csv(OUT_DIR / "per_frame_analysis_v2.csv", index=False)

    df["oracle"] = df.apply(
        lambda r: "ft" if r.ft_cd <= min(r.fg_cd, r.lt_cd) else ("fg" if r.fg_cd <= r.lt_cd else "lt"),
        axis=1,
    )
    df["superpc_helps"] = df["oracle"].isin(["fg", "lt"])

    print("\nTier distribution:", df.tier.value_counts().to_dict())
    for t in ["skip", "lite", "full"]:
        report(df[df.tier == t], f"tier={t}")
    for seq in ["TrumanShow", "VictoryHeart", "VirtualLife"]:
        report(df[df.sequence == seq], seq)

    print("\nOracle:", df.oracle.value_counts().to_dict())
    oracle_cd = df.apply(lambda r: min(r.ft_cd, r.fg_cd, r.lt_cd), axis=1).mean()
    print(f"Oracle CD: {oracle_cd:.4f}  ft={df.ft_cd.mean():.4f} fg={df.fg_cd.mean():.4f}")

    sp = df[df.superpc_helps]
    pure = df[~df.superpc_helps]
    print("\n--- Oracle SuperPC-helpful vs pure-ft frames ---")
    for col in ["est_lite_add", "est_full_add", "spacing_med", "ft_cd", "ft_comp", "ft_hole", "cg_cd"]:
        print(f"  {col:14s} helps={sp[col].mean():.4f}  pure_ft={pure[col].mean():.4f}")

    print("\n--- est_lite_add threshold sweep ---")
    for thr in [0.01, 0.022, 0.03, 0.04, 0.055, 0.08, 0.10]:
        use = df.est_lite_add >= thr
        skip = ~use
        rec = df.loc[use, "superpc_helps"].sum() / max(sp.shape[0], 1)
        print(
            f"  thr={thr:.3f} use={use.sum():3d} d_use={df.loc[use,'d_fg_ft'].mean():+.4f} "
            f"skip={skip.sum():3d} d_skip={df.loc[skip,'d_fg_ft'].mean():+.4f} oracle_rec={rec:.2%}"
        )

    print("\n--- ft_hole (comp-acc) sweep ---")
    for thr in [-1, 0, 0.5, 1.0, 1.5, 2.0, 3.0]:
        sub = df[df.ft_hole > thr]
        if sub.empty:
            continue
        print(
            f"  ft_hole>{thr}: n={len(sub)} helps_rate={sub.superpc_helps.mean():.1%} "
            f"d_fg_ft={sub.d_fg_ft.mean():+.4f}"
        )

    print("\n--- Combined rules ---")
    for name, mask in [
        ("TS & est>=4%", (df.sequence == "TrumanShow") & (df.est_lite_add >= 0.04)),
        ("TS & est>=5.5%", (df.sequence == "TrumanShow") & (df.est_lite_add >= 0.055)),
        ("est>=5.5% any seq", df.est_lite_add >= 0.055),
        ("est>=8%", df.est_lite_add >= 0.08),
        ("TS & ft_hole>1", (df.sequence == "TrumanShow") & (df.ft_hole > 1.0)),
        ("skip tier only", df.tier == "skip"),
        ("full tier only", df.tier == "full"),
    ]:
        sub = df[mask]
        if sub.empty:
            continue
        print(
            f"  {name:22s} n={len(sub):3d} d_fg_ft={sub.d_fg_ft.mean():+.4f} "
            f"wins={(sub.d_fg_ft<0).sum():3d} oracle_sp={sub.superpc_helps.mean():.1%}"
        )

    # What current frame_gate actually did vs optimal
    print("\n--- Current gate tier vs outcome ---")
    for t in ["skip", "lite", "full"]:
        sub = df[df.tier == t]
        if sub.empty:
            continue
        print(f"  assigned {t}: should_be_ft={( sub.oracle=='ft').sum()} should_be_sp={(sub.oracle!='ft').sum()}")

    summary = {
        "oracle_cd": float(oracle_cd),
        "ft_cd": float(df.ft_cd.mean()),
        "fg_cd": float(df.fg_cd.mean()),
        "tier_counts": df.tier.value_counts().to_dict(),
        "helps_by_seq": df[df.d_fg_ft < 0].groupby("sequence").size().to_dict(),
        "hurts_by_seq": df[df.d_fg_ft > 0].groupby("sequence").size().to_dict(),
        "recommendation": {
            "use_superpc_when": [
                "sequence == TrumanShow AND est_lite_add >= 0.055 (~full tier)",
                "ft completeness-limited: ft_comp - ft_acc > 1.0 (mainly TS sparse blocks)",
            ],
            "never_use_superpc": [
                "VictoryHeart: 0/197 frames benefit from frame_gate vs ft",
                "est_lite_add < 0.022 (VH typical): pure ft is optimal",
            ],
        },
    }
    json.dump(summary, open(OUT_DIR / "superpc_use_analysis.json", "w"), indent=2)
    print(f"\nwrote {OUT_DIR / 'superpc_use_analysis.json'}")


if __name__ == "__main__":
    main()
