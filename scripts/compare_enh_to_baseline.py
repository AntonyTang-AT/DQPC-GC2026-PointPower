#!/usr/bin/env python3
"""Compare Enhancement Only metrics against official ACMMM26_GC_baseline.csv."""
from __future__ import annotations

import argparse
import json
import os
from datetime import datetime

import pandas as pd

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GC2026_ROOT = os.path.dirname(SCRIPT_DIR)

FOCUS_METRICS = [
    "accuracy",
    "completeness",
    "hausdorff_distance",
    "precision_10.0",
    "recall_10.0",
    "fscore_10.0",
]

LOWER_BETTER = {"accuracy", "completeness", "hausdorff_distance", "chamfer_distance"}
HIGHER_BETTER = {"precision_10.0", "recall_10.0", "fscore_10.0"}


def load_baseline(path: str) -> pd.DataFrame:
    df = pd.read_csv(path)
    df["join_key"] = df["test_file"].astype(str)
    return df


def load_enh_csv(path: str) -> pd.DataFrame:
    df = pd.read_csv(path)
    if "test_file" not in df.columns:
        raise ValueError(f"Missing test_file in {path}")
    # ENH eval uses ENH filenames; map back to CG key for baseline join.
    df["join_key"] = df["test_file"].astype(str).str.replace("_ENH_", "_CG_", 1)
    return df


def summarize_delta(baseline: pd.DataFrame, enh: pd.DataFrame, metrics: list[str]) -> dict:
    merged = baseline.merge(
        enh,
        on="join_key",
        suffixes=("_baseline", "_enh"),
        how="inner",
    )
    out: dict = {"num_matched_frames": int(len(merged))}
    for m in metrics:
        bcol, ecol = f"{m}_baseline", f"{m}_enh"
        if bcol not in merged.columns or ecol not in merged.columns:
            continue
        bmean = float(merged[bcol].mean())
        emean = float(merged[ecol].mean())
        delta = emean - bmean
        if m in LOWER_BETTER:
            improved = delta < 0
            pct = (bmean - emean) / bmean * 100.0 if bmean else 0.0
        else:
            improved = delta > 0
            pct = (emean - bmean) / bmean * 100.0 if bmean else 0.0
        out[m] = {
            "baseline_mean": bmean,
            "enh_mean": emean,
            "delta_enh_minus_baseline": delta,
            "relative_improvement_pct": pct,
            "improved": improved,
        }
    return out


def per_sequence_delta(baseline: pd.DataFrame, enh: pd.DataFrame) -> list[dict]:
    merged = baseline.merge(enh, on="join_key", suffixes=("_b", "_e"), how="inner")
    if "source_filename" in merged.columns:
        merged["sequence"] = merged["source_filename"].str.replace("_baseline_metrics.csv", "", regex=False)
    elif "sequence_e" in merged.columns:
        merged["sequence"] = merged["sequence_e"]
    else:
        merged["sequence"] = merged["join_key"].str.split("_").str[0]

    rows: list[dict] = []
    for seq, grp in merged.groupby("sequence"):
        row = {"sequence": seq, "n_frames": int(len(grp))}
        for m in FOCUS_METRICS:
            bcol, ecol = f"{m}_b", f"{m}_e"
            if bcol not in grp.columns:
                bcol = m if m in grp.columns else None
                ecol = m if m in grp.columns else None
            if not bcol or not ecol:
                continue
            bmean = float(grp[bcol].mean())
            emean = float(grp[ecol].mean())
            row[f"{m}_baseline"] = bmean
            row[f"{m}_enh"] = emean
            row[f"{m}_delta"] = emean - bmean
        rows.append(row)
    rows.sort(key=lambda r: r.get("fscore_10.0_delta", 0.0), reverse=True)
    return rows


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument(
        "--baseline-csv",
        default=os.path.join(GC2026_ROOT, "ACMMM26_GC_baseline.csv"),
    )
    p.add_argument("--enh-csv", required=True)
    p.add_argument("--out-json", default=None)
    return p.parse_args()


def main() -> None:
    args = parse_args()
    baseline = load_baseline(args.baseline_csv)
    enh = load_enh_csv(args.enh_csv)

    summary = summarize_delta(baseline, enh, FOCUS_METRICS + ["chamfer_distance"])
    by_seq = per_sequence_delta(baseline, enh)

    report = {
        "baseline_csv": args.baseline_csv,
        "enh_csv": args.enh_csv,
        "focus_metrics": FOCUS_METRICS,
        "note": "Baseline = aligned CG vs HE. ENH should use same alignment + HE GT.",
        "overall": summary,
        "per_sequence": by_seq,
        "created_at": datetime.utcnow().isoformat() + "Z",
    }

    out = args.out_json or args.enh_csv.replace(".csv", "_vs_baseline.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)

    print(json.dumps({"overall": summary, "out": out}, indent=2))
    print("\nPer-sequence fscore_10.0 delta (top 5):")
    for row in by_seq[:5]:
        print(
            f"  {row['sequence']}: delta={row.get('fscore_10.0_delta', 'n/a'):.4f} "
            f"(baseline {row.get('fscore_10.0_baseline', 'n/a'):.3f} -> enh {row.get('fscore_10.0_enh', 'n/a'):.3f})"
        )


if __name__ == "__main__":
    main()
