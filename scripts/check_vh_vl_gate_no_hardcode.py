#!/usr/bin/env python3
"""
Verify: what est_add_ratio would VH/VL get if no hard skip?
We only need a random sample (~10 frames per seq) to confirm.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

from enh_refine_config import resolve_preset
from enh_refine_pipeline import output_ply_path
from frame_fill_gate import decide_frame_fill_gate
from uvg_io import read_ply_xyz_rgb

V2_EV = ROOT / "output/ft_val565_fusion/holefill_adaptive_frame_gate_v2/evaluation_gc_baseline_val565.json"
GEOM_PRIMARY = ROOT / "output/pdlts_finetune_uvg/val565/light"
GEOM_SECONDARY = ROOT / "output/submission_candidate"


def main():
    extra = resolve_preset("holefill_adaptive_frame_gate_v2").extra
    # Remove skip_sequences to simulate no hard skip
    extra.pop("frame_fill_gate_skip_sequences", None)

    # Load random VH/VL frames
    ev = json.load(open(V2_EV))
    candidates = []
    for r in ev["records"]:
        if r.get("error"):
            continue
        seq = r["sequence"]
        if seq in ("VictoryHeart", "VirtualLife"):
            candidates.append(r["cg_path"])

    # Pick every 20th frame
    sample = candidates[::20] + [candidates[-1]]
    print(f"VH/VL candidates: {len(candidates)}, sampling {len(sample)}")

    results = {}
    for cg in sample:
        seq = None
        for r in ev["records"]:
            if r.get("cg_path") == cg:
                seq = r["sequence"]
                break
        try:
            cg_xyz, _ = read_ply_xyz_rgb(cg)
            pr_xyz, _ = read_ply_xyz_rgb(output_ply_path(str(GEOM_PRIMARY), cg))
            sec_path = output_ply_path(str(GEOM_SECONDARY), cg)
            if os.path.isfile(sec_path):
                sec_xyz, _ = read_ply_xyz_rgb(sec_path)
            else:
                sec_xyz = None
            tier, metrics = decide_frame_fill_gate(cg_xyz, pr_xyz, extra, sec_xyz)
            results[Path(cg).stem] = {
                "sequence": seq,
                "tier": tier,
                "est_add_ratio": round(float(metrics.get("frame_fill_gate_est_add_ratio", 0.0)), 5),
                "spacing_p90": round(float(metrics.get("frame_fill_gate_cg_spacing_p90_mm", 0.0)), 3),
            }
        except Exception as e:
            results[Path(cg).stem] = {"error": str(e)}

    print(f"\n{'Frame':30s} {'Seq':15s} {'tier':8s} {'est_add':>10s} {'spacing_p90':>10s}")
    print("-" * 75)
    for name, r in results.items():
        if "error" in r:
            print(f"{name:30s} ERROR: {r['error']}")
        else:
            print(f"{name:30s} {r['sequence']:15s} {r['tier']:8s} {r['est_add_ratio']:>10.5f} {r['spacing_p90']:>10.3f}")

    # Summary
    arts = [r["est_add_ratio"] for r in results.values() if "error" not in r]
    if arts:
        print(f"\nSummary: min={min(arts):.5f} max={max(arts):.5f} mean={np.mean(arts):.5f}")
        print(f"  All < 0.022? {all(a < 0.022 for a in arts)}")
        print(f"  All < 0.040? {all(a < 0.040 for a in arts)}")


if __name__ == "__main__":
    os.chdir(ROOT)
    main()
