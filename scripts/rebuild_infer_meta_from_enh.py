#!/usr/bin/env python3
"""Rebuild infer_meta.json by scanning ENH PLYs and merging submission timing."""
from __future__ import annotations

import argparse
import glob
import json
import os
from datetime import datetime, timezone


def load_records(path: str) -> dict[str, dict]:
    if not os.path.isfile(path):
        return {}
    data = json.load(open(path, encoding="utf-8"))
    by_name: dict[str, dict] = {}
    for r in data.get("records", []):
        out = r.get("out_path", "")
        if out:
            by_name[os.path.basename(out)] = r
    return by_name


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--enh-root", required=True)
    p.add_argument("--recon-root", required=True)
    p.add_argument("--timing-json", default="", help="Fallback timing source (e.g. submission infer_meta)")
    p.add_argument("--out-json", default="")
    args = p.parse_args()

    timing = load_records(args.timing_json) if args.timing_json else {}
    records: list[dict] = []
    for ply in sorted(glob.glob(os.path.join(args.enh_root, "*", "*.ply"))):
        fname = os.path.basename(ply)
        seq = os.path.basename(os.path.dirname(ply))
        cg_name = fname.replace("_ENH_", "_CG_", 1)
        recon = os.path.join(args.recon_root, seq, cg_name)
        base = timing.get(fname, {})
        records.append(
            {
                "cg_path": recon if os.path.isfile(recon) else "",
                "out_path": os.path.abspath(ply),
                "input_points": base.get("input_points", 0),
                "output_points": base.get("output_points", 0),
                "output_mode": base.get("output_mode", "blend_cg"),
                "blend_voxel_mm": base.get("blend_voxel_mm", 3.0),
                "checkpoint": base.get("checkpoint", "kitti360_com.pth"),
                "seconds": float(base.get("seconds", 0.0)),
            }
        )

    out_path = args.out_json or os.path.join(args.enh_root, "infer_meta.json")
    payload = {
        "rebuilt_at": datetime.now(timezone.utc).isoformat(),
        "num_records": len(records),
        "timing_source": os.path.abspath(args.timing_json) if args.timing_json else None,
        "records": records,
    }
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)
    print(f"Written {len(records)} records -> {out_path}")


if __name__ == "__main__":
    main()
