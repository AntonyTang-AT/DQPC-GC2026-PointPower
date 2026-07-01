#!/usr/bin/env python3
"""Merge val565 gc_baseline CSVs into one Excel workbook (sheet1, sheet2, ...)."""
from __future__ import annotations

import argparse
import csv
import json
import os
import re
from datetime import datetime, timezone

import pandas as pd

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GC2026_ROOT = os.path.dirname(SCRIPT_DIR)

VAL_SEQS = ("TrumanShow", "VictoryHeart", "VirtualLife")

DELIVERY_REL = "docs/meeting_delivery"

SHEET_CSVS = [
    ("sheet3_superpc_blend_cg", f"{DELIVERY_REL}/metrics/01_superpc_blend_cg_kitti360_vx3.0_val565.csv"),
    ("sheet4_pdlts_vh_snap0", f"{DELIVERY_REL}/metrics/02_pdlts_vh_snap0_val565.csv"),
    ("sheet5_pdlts_density", f"{DELIVERY_REL}/metrics/03_pdlts_density_global_snap_no_vh_tune_val565.csv"),
    ("sheet6_pdlts_raw", f"{DELIVERY_REL}/metrics/04_pdlts_raw_val565.csv"),
    ("sheet7_superpc_filter_snap1", f"{DELIVERY_REL}/metrics/05_superpc_filter_snap1.0_val565.csv"),
    ("sheet8_ft_density_finetune", f"{DELIVERY_REL}/metrics/06b_ft_density_finetune_val565.csv"),
    ("sheet9_holefill_lite", f"{DELIVERY_REL}/metrics/06_holefill_lite_val565.csv"),
    ("sheet10_line_b_holefill", f"{DELIVERY_REL}/metrics/07_line_b_holefill_first_val565.csv"),
    ("sheet11_frame_gate_v2", f"{DELIVERY_REL}/metrics/08_frame_gate_v2_val565.csv"),
]

OPTIONAL_SHEETS = {s[0]: s[1] for s in SHEET_CSVS[5:]}


def read_csv(path: str) -> pd.DataFrame:
    return pd.read_csv(path)


def filter_baseline_val565(baseline_csv: str) -> pd.DataFrame:
    df = read_csv(baseline_csv)
    pat = re.compile(r"^(" + "|".join(re.escape(s) for s in VAL_SEQS) + ")_")
    mask = df["test_file"].astype(str).str.match(pat)
    out = df.loc[mask].copy().reset_index(drop=True)
    if "frame" not in out.columns:
        out.insert(0, "frame", range(len(out)))
    else:
        out["frame"] = range(len(out))
    return out


def per_seq_means_from_eval_json(path: str) -> dict[str, float]:
    from collections import defaultdict

    d = json.load(open(path, encoding="utf-8"))
    acc: dict[str, list[float]] = defaultdict(list)
    for r in d.get("records", []):
        if r.get("error"):
            continue
        acc[r["sequence"]].append(float(r["chamfer_distance"]))
    return {s: float(sum(v) / len(v)) for s, v in acc.items()}


def per_seq_from_preference(path: str, key: str) -> dict[str, float]:
    pref = json.load(open(path, encoding="utf-8"))
    return {r["sequence"]: float(r[key]) for r in pref.get("sequences", []) if key in r}


def summary_rows() -> tuple[pd.DataFrame, pd.DataFrame]:
    summary_path = os.path.join(GC2026_ROOT, "output/meeting_delivery/metrics/summary.json")
    rows: list[dict] = []
    seen: set[str] = set()
    if os.path.isfile(summary_path):
        data = json.load(open(summary_path, encoding="utf-8"))
        for m in data.get("models", []):
            rows.append(
                {
                    "model": m["name"],
                    "mean_chamfer_distance_mm": m.get("mean_chamfer_distance"),
                    "num_frames": m.get("num_frames"),
                    "TrumanShow": (m.get("per_sequence_mean_chamfer") or {}).get("TrumanShow"),
                    "VictoryHeart": (m.get("per_sequence_mean_chamfer") or {}).get("VictoryHeart"),
                    "VirtualLife": (m.get("per_sequence_mean_chamfer") or {}).get("VirtualLife"),
                }
            )
            seen.add(m["name"])

    raw_json = os.path.join(GC2026_ROOT, "output/pdlts_val565/light/evaluation_gc_baseline_val565.json")
    if "pdlts_raw" not in seen and os.path.isfile(raw_json):
        s = json.load(open(raw_json, encoding="utf-8"))["summary"]
        ps = per_seq_means_from_eval_json(raw_json)
        rows.append(
            {
                "model": "pdlts_raw",
                "mean_chamfer_distance_mm": s["means"]["chamfer_distance"],
                "num_frames": s.get("num_evaluated", 564),
                "TrumanShow": ps.get("TrumanShow"),
                "VictoryHeart": ps.get("VictoryHeart"),
                "VirtualLife": ps.get("VirtualLife"),
            }
        )

    rec = os.path.join(GC2026_ROOT, "output/meeting_delivery/metrics/superpc_filter_snap1.0_phase2_record.json")
    pref = os.path.join(GC2026_ROOT, "output/enh_refine_phase2/per_sequence_model_preference.json")
    if "superpc_filter_snap1.0" not in seen and os.path.isfile(rec):
        r = json.load(open(rec, encoding="utf-8"))
        ps = per_seq_from_preference(pref, "superpc_filter") if os.path.isfile(pref) else {}
        rows.append(
            {
                "model": "superpc_filter_snap1.0",
                "mean_chamfer_distance_mm": r.get("mean_enh_chamfer_distance"),
                "num_frames": r.get("num_frames_val565", 564),
                "TrumanShow": ps.get("TrumanShow"),
                "VictoryHeart": ps.get("VictoryHeart"),
                "VirtualLife": ps.get("VirtualLife"),
            }
        )

    rows.append(
        {
            "model": "cg_baseline_official",
            "mean_chamfer_distance_mm": 17.551553246708043,
            "num_frames": 564,
            "TrumanShow": 19.337026652126585,
            "VictoryHeart": 16.214444610694784,
            "VirtualLife": 17.337749414912338,
        }
    )

    meta = pd.DataFrame(
        [
            {"key": "metric", "value": "chamfer_distance = (accuracy + completeness) / 2"},
            {"key": "eval_mode", "value": "gc_baseline_aligned (official alignment matrix)"},
            {"key": "pairs", "value": "val565: TrumanShow + VictoryHeart + VirtualLife"},
            {"key": "sheet6", "value": "PD-LTS light only, no snap/fill refine (564 per-frame)"},
            {
                "key": "sheet7",
                "value": "SuperPC filter_cg + snap1mm Phase2; per-seq + aggregate (per-frame CSV deleted)",
            },
            {"key": "docs", "value": "docs/meeting_delivery/VAL565_METRICS_XLSX.md"},
            {"key": "generated_at", "value": datetime.now(timezone.utc).isoformat()},
        ]
    )
    return pd.DataFrame(rows), meta


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument(
        "--out-xlsx",
        default=os.path.join(GC2026_ROOT, "docs/meeting_delivery/val565_gc_baseline_metrics.xlsx"),
    )
    p.add_argument("--baseline-csv", default=os.path.join(GC2026_ROOT, "ACMMM26_GC_baseline.csv"))
    args = p.parse_args()

    os.makedirs(os.path.dirname(args.out_xlsx) or ".", exist_ok=True)

    summary_df, meta_df = summary_rows()

    with pd.ExcelWriter(args.out_xlsx, engine="openpyxl") as writer:
        summary_df.to_excel(writer, sheet_name="sheet1_summary", index=False)
        meta_df.to_excel(writer, sheet_name="sheet1_meta", index=False)

        df2 = filter_baseline_val565(args.baseline_csv)
        df2.to_excel(writer, sheet_name="sheet2_cg_baseline", index=False)

        for sheet_name, rel_path in SHEET_CSVS:
            path = os.path.join(GC2026_ROOT, rel_path)
            if not os.path.isfile(path):
                if sheet_name in OPTIONAL_SHEETS:
                    continue
                raise FileNotFoundError(path)
            read_csv(path).to_excel(writer, sheet_name=sheet_name, index=False)

    sheet_names = ["sheet1_summary", "sheet1_meta", "sheet2_cg_baseline"] + [
        s[0] for s in SHEET_CSVS if os.path.isfile(os.path.join(GC2026_ROOT, s[1]))
    ]
    print(json.dumps({"out_xlsx": args.out_xlsx, "sheets": sheet_names}, indent=2))


if __name__ == "__main__":
    main()
