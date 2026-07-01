#!/usr/bin/env python3
"""Copy ENH PLYs from Enhancement-Only track when Stage1 recon == official CG."""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from datetime import datetime, timezone

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GC2026_ROOT = os.path.dirname(SCRIPT_DIR)
sys.path.insert(0, SCRIPT_DIR)


def enh_path_from_recon(recon_path: str, enh_root: str) -> str:
    seq = os.path.basename(os.path.dirname(recon_path))
    fname = os.path.basename(recon_path).replace("_CG_", "_ENH_", 1)
    return os.path.join(enh_root, seq, fname)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument(
        "--recon-list",
        required=True,
        help="Recon CG paths (one per line)",
    )
    p.add_argument(
        "--src-enh-root",
        default=os.path.join(GC2026_ROOT, "output/submission_candidate"),
    )
    p.add_argument(
        "--dst-enh-root",
        default=os.path.join(GC2026_ROOT, "output/full_pipeline_n0_v2_candidate"),
    )
    p.add_argument("--dry-run", action="store_true")
    p.add_argument(
        "--out-json",
        default=os.path.join(GC2026_ROOT, "output/stage1_backfill_enh_copy.json"),
    )
    args = p.parse_args()

    recon_paths = [ln.strip() for ln in open(args.recon_list, encoding="utf-8") if ln.strip()]
    applied: list[dict] = []
    skipped: list[dict] = []

    for recon_path in recon_paths:
        dst = enh_path_from_recon(recon_path, args.dst_enh_root)
        src = enh_path_from_recon(recon_path, args.src_enh_root)
        entry = {"recon_path": recon_path, "src_enh": src, "dst_enh": dst}
        if not os.path.isfile(src):
            entry["reason"] = "missing_src_enh"
            skipped.append(entry)
            continue
        if args.dry_run:
            applied.append(entry)
            continue
        backup_dir = os.path.join(args.dst_enh_root, "_bad_enh_backup", os.path.basename(os.path.dirname(dst)))
        if os.path.isfile(dst):
            os.makedirs(backup_dir, exist_ok=True)
            bak = os.path.join(backup_dir, os.path.basename(dst))
            if not os.path.isfile(bak):
                shutil.copy2(dst, bak)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(src, dst)
        applied.append(entry)

    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "src_enh_root": args.src_enh_root,
        "dst_enh_root": args.dst_enh_root,
        "num_requested": len(recon_paths),
        "num_copied": len(applied),
        "num_skipped": len(skipped),
        "skipped_sample": skipped[:10],
    }
    os.makedirs(os.path.dirname(args.out_json) or ".", exist_ok=True)
    with open(args.out_json, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)
    print(json.dumps({k: report[k] for k in ("num_requested", "num_copied", "num_skipped")}, indent=2))
    print(f"Written: {args.out_json}")


if __name__ == "__main__":
    main()
