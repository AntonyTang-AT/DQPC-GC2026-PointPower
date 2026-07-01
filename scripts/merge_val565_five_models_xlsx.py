#!/usr/bin/env python3
"""Merge five canonical val565 model CSVs into one Excel workbook."""
from __future__ import annotations

import argparse
import json
import os
import re
from datetime import datetime, timezone

import pandas as pd

GC2026_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
METRICS_REL = "docs/meeting_delivery/metrics"

MODEL_CSVS = [
    ("sheet3_superpc_only", f"{METRICS_REL}/01_superpc_best_val565.csv"),
    ("sheet4_pdlts_frozen_only", f"{METRICS_REL}/02_pdlts_frozen_best_val565.csv"),
    ("sheet5_pdlts_finetune_only", f"{METRICS_REL}/03_pdlts_finetune_best_val565.csv"),
    ("sheet6_fusion_frozen_pdlts", f"{METRICS_REL}/04_fusion_frozen_pdlts_best_val565.csv"),
    ("sheet7_fusion_finetune_pdlts", f"{METRICS_REL}/05_fusion_finetune_pdlts_best_val565.csv"),
]


def filter_baseline_val565(baseline_csv: str) -> pd.DataFrame:
    val_seqs = ("TrumanShow", "VictoryHeart", "VirtualLife")
    df = pd.read_csv(baseline_csv)
    pat = re.compile(r"^(" + "|".join(re.escape(s) for s in val_seqs) + ")_")
    mask = df["test_file"].astype(str).str.match(pat)
    out = df.loc[mask].copy().reset_index(drop=True)
    if "frame" not in out.columns:
        out.insert(0, "frame", range(len(out)))
    else:
        out["frame"] = range(len(out))
    return out


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument(
        "--out-xlsx",
        default=os.path.join(GC2026_ROOT, "docs/meeting_delivery/val565_five_models.xlsx"),
    )
    p.add_argument("--baseline-csv", default=os.path.join(GC2026_ROOT, "ACMMM26_GC_baseline.csv"))
    p.add_argument("--registry", default=os.path.join(GC2026_ROOT, METRICS_REL, "models_registry.json"))
    args = p.parse_args()

    registry = json.load(open(args.registry, encoding="utf-8"))
    summary_rows = []
    for cat in registry["categories"]:
        ps = cat.get("per_sequence_mean_chamfer") or {}
        summary_rows.append(
            {
                "category_id": cat["id"],
                "label": cat["label"],
                "preset": cat["preset"],
                "mean_chamfer_distance_mm": cat["mean_chamfer_mm"],
                "num_frames": cat.get("num_frames", 564),
                "TrumanShow": ps.get("TrumanShow"),
                "VictoryHeart": ps.get("VictoryHeart"),
                "VirtualLife": ps.get("VirtualLife"),
                "role": cat.get("role", ""),
            }
        )
    summary_rows.append(
        {
            "category_id": "cg_baseline",
            "label": "CG baseline（未增强）",
            "preset": "official CGv2",
            "mean_chamfer_distance_mm": 17.551553246708043,
            "num_frames": 564,
            "TrumanShow": 19.337026652126585,
            "VictoryHeart": 16.214444610694784,
            "VirtualLife": 17.337749414912338,
            "role": "reference",
        }
    )

    meta = pd.DataFrame(
        [
            {"key": "metric", "value": "chamfer_distance = (accuracy + completeness) / 2"},
            {"key": "eval_mode", "value": "gc_baseline_aligned"},
            {"key": "pairs", "value": "val565: TrumanShow + VictoryHeart + VirtualLife (564 frames)"},
            {"key": "docs", "value": "docs/meeting_delivery/README.md"},
            {"key": "generated_at", "value": datetime.now(timezone.utc).isoformat()},
        ]
    )

    os.makedirs(os.path.dirname(args.out_xlsx) or ".", exist_ok=True)
    with pd.ExcelWriter(args.out_xlsx, engine="openpyxl") as writer:
        pd.DataFrame(summary_rows).to_excel(writer, sheet_name="sheet1_summary", index=False)
        meta.to_excel(writer, sheet_name="sheet1_meta", index=False)
        filter_baseline_val565(args.baseline_csv).to_excel(writer, sheet_name="sheet2_cg_baseline", index=False)
        for sheet_name, rel in MODEL_CSVS:
            path = os.path.join(GC2026_ROOT, rel)
            if not os.path.isfile(path):
                raise FileNotFoundError(path)
            pd.read_csv(path).to_excel(writer, sheet_name=sheet_name, index=False)

    print(json.dumps({"out_xlsx": args.out_xlsx}, indent=2))


if __name__ == "__main__":
    main()
