#!/usr/bin/env python3
"""Refresh output/compliance_eval_summary.json from current eval artifacts."""
from __future__ import annotations

import json
import os
from datetime import datetime, timezone

GC2026_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SUMMARY = os.path.join(GC2026_ROOT, "output/compliance_eval_summary.json")
STATE = os.path.join(GC2026_ROOT, "output/compliance_eval_plan.state")
SRC_TAR = os.path.join(GC2026_ROOT, "output/GC2026_Team_submission_src.tar.gz")

ENH_VAL = os.path.join(GC2026_ROOT, "output/submission_candidate/evaluation_official_val_n20k.json")
FULL_VAL = os.path.join(GC2026_ROOT, "output/full_pipeline_n0_v2_candidate/evaluation_official_val_n20k.json")
ENH_METRIC = os.path.join(GC2026_ROOT, "output/submission_candidate/evaluation_official_metric_val565.json")
FULL_METRIC = os.path.join(GC2026_ROOT, "output/full_pipeline_n0_v2_candidate/evaluation_official_metric_val565.json")


def load_json(path: str) -> dict | None:
    if os.path.isfile(path):
        return json.load(open(path, encoding="utf-8"))
    return None


def pick_summary(path: str) -> dict | None:
    d = load_json(path)
    if not d:
        return None
    return d.get("summary", d)


def load_state() -> dict:
    state: dict = {}
    if os.path.isfile(STATE):
        for ln in open(STATE, encoding="utf-8"):
            if "=" in ln.strip():
                k, v = ln.strip().split("=", 1)
                state[k] = v
    state["backfill_fix"] = datetime.now(timezone.utc).isoformat()
    return state


def main() -> None:
    prev = load_json(SUMMARY) or {}
    out = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "finish_reason": prev.get("finish_reason", "success"),
        "note": "Refreshed after Stage1 backfill fix (2026-06-21)",
        "max_runtime_hours": prev.get("max_runtime_hours", 5),
        "plan_state": load_state(),
        "artifacts": {
            "submission_src_tar": SRC_TAR if os.path.isfile(SRC_TAR) else None,
            "full_manifest": f"{GC2026_ROOT}/output/full_pipeline_n0_v2_candidate/manifest.json",
            "enh_manifest": f"{GC2026_ROOT}/output/submission_candidate/manifest.json",
            "full_official_metric": FULL_METRIC if os.path.isfile(FULL_METRIC) else None,
            "enh_official_metric": ENH_METRIC if os.path.isfile(ENH_METRIC) else None,
            "stage1_backfill_fix": f"{GC2026_ROOT}/output/stage1_backfill_fix_summary.json",
        },
        "metrics": {
            "enh_official_uvg": pick_summary(ENH_VAL),
            "full_official_uvg": pick_summary(FULL_VAL),
            "enh_official_metric": pick_summary(ENH_METRIC),
            "full_official_metric": pick_summary(FULL_METRIC),
        },
    }
    json.dump(out, open(SUMMARY, "w", encoding="utf-8"), indent=2)
    print(f"Written {SUMMARY}")


if __name__ == "__main__":
    main()
