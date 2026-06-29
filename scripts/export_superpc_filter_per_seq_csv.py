#!/usr/bin/env python3
"""Export Phase2 superpc_filter per-sequence summary (per-frame CSV no longer on disk)."""
from __future__ import annotations

import argparse
import csv
import json
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GC2026_ROOT = os.path.dirname(SCRIPT_DIR)

DEFAULT_PREF = os.path.join(GC2026_ROOT, "output/enh_refine_phase2/per_sequence_model_preference.json")
DEFAULT_RECORD = os.path.join(
    GC2026_ROOT, "docs/meeting_delivery/metrics/superpc_filter_snap1.0_phase2_record.json"
)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--pref-json", default=DEFAULT_PREF)
    p.add_argument("--record-json", default=DEFAULT_RECORD)
    p.add_argument(
        "--out-csv",
        default=os.path.join(GC2026_ROOT, "docs/meeting_delivery/metrics/05_superpc_filter_snap1.0_val565.csv"),
    )
    args = p.parse_args()

    pref = json.load(open(args.pref_json, encoding="utf-8"))
    record = json.load(open(args.record_json, encoding="utf-8")) if os.path.isfile(args.record_json) else {}

    rows = []
    for seq_row in pref.get("sequences", []):
        seq = seq_row["sequence"]
        cg = seq_row.get("CG")
        enh = seq_row.get("superpc_filter")
        rows.append(
            {
                "granularity": "per_sequence_mean",
                "sequence": seq,
                "chamfer_distance": enh,
                "cg_chamfer_distance": cg,
                "improvement_cg_minus_enh": (cg - enh) if cg is not None and enh is not None else "",
                "num_frames": "",
                "note": "Phase2 superpc_filter_cg + snap1mm; per-frame CSV deleted",
            }
        )

    rows.append(
        {
            "granularity": "val565_aggregate",
            "sequence": "ALL",
            "chamfer_distance": record.get("mean_enh_chamfer_distance", 18.3528080857124),
            "cg_chamfer_distance": record.get("cg_baseline_chamfer_distance", 17.551553246708043),
            "improvement_cg_minus_enh": record.get("improvement_cg_minus_enh", -0.8012548390043577),
            "num_frames": record.get("num_frames_val565", 564),
            "note": "Same aggregate as filter_cg+snap1 (geometry cache deleted)",
        }
    )

    os.makedirs(os.path.dirname(args.out_csv) or ".", exist_ok=True)
    fields = [
        "granularity",
        "sequence",
        "chamfer_distance",
        "cg_chamfer_distance",
        "improvement_cg_minus_enh",
        "num_frames",
        "note",
    ]
    with open(args.out_csv, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)
    print(f"Wrote {args.out_csv} ({len(rows)} rows)")


if __name__ == "__main__":
    main()
