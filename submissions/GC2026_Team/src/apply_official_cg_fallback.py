#!/usr/bin/env python3
"""Replace bad Stage1 recon PLYs with official CG copies (backup originals)."""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from datetime import datetime

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GC2026_ROOT = os.path.dirname(SCRIPT_DIR)
sys.path.insert(0, SCRIPT_DIR)

from compare_reconstructed_cg import recon_path_from_cg  # noqa: E402


def load_cg_paths_from_audit(audit_json: str, min_cd_l1: float, val_only: bool) -> list[str]:
    data = json.load(open(audit_json, encoding="utf-8"))
    out: list[str] = []
    for r in data.get("records", []):
        cd = r.get("recon_vs_official_cg_cd_l1")
        if cd is None or cd < min_cd_l1:
            continue
        if val_only and not r.get("is_backfill_candidate"):
            continue
        cg = r.get("cg_path")
        if cg:
            out.append(cg)
    return sorted(set(out))


def load_cg_paths_from_list(list_path: str, val_pairs_file: str, val_only: bool) -> list[str]:
    val_cgs: set[str] = set()
    if val_only and os.path.isfile(val_pairs_file):
        for ln in open(val_pairs_file, encoding="utf-8"):
            ln = ln.strip()
            if not ln:
                continue
            parts = ln.split("\t")
            if parts:
                val_cgs.add(parts[0])
    out: list[str] = []
    for ln in open(list_path, encoding="utf-8"):
        cg = ln.strip()
        if not cg or cg.startswith("#"):
            continue
        if val_only and cg not in val_cgs:
            continue
        out.append(cg)
    return out


def main() -> None:
    p = argparse.ArgumentParser(description="Official CG fallback for bad Stage1 recon")
    p.add_argument(
        "--recon-root",
        default=os.path.join(GC2026_ROOT, "output/full_pipeline_n0_v2_cg"),
    )
    p.add_argument(
        "--audit-json",
        default=os.path.join(GC2026_ROOT, "output/stage1_p0_audit.json"),
    )
    p.add_argument(
        "--cg-list",
        default="",
        help="One official CG path per line (overrides audit selection when set)",
    )
    p.add_argument(
        "--val-pairs-file",
        default=os.path.join(GC2026_ROOT, "data/processed/val_pairs_official_cgv2.txt"),
    )
    p.add_argument("--min-cd-l1", type=float, default=500.0)
    p.add_argument(
        "--val-only",
        action="store_true",
        help="Only frames flagged as backfill in official val565 audit",
    )
    p.add_argument(
        "--all-backfill-list",
        action="store_true",
        help="Use _retry_missing.txt intersect val when --val-only; full list otherwise",
    )
    p.add_argument("--dry-run", action="store_true")
    p.add_argument(
        "--out-json",
        default=os.path.join(GC2026_ROOT, "output/stage1_official_cg_fallback.json"),
    )
    args = p.parse_args()

    if args.cg_list:
        cg_paths = load_cg_paths_from_list(args.cg_list, args.val_pairs_file, args.val_only)
    elif args.all_backfill_list:
        list_path = os.path.join(args.recon_root, "_retry_missing.txt")
        cg_paths = load_cg_paths_from_list(list_path, args.val_pairs_file, args.val_only)
    elif os.path.isfile(args.audit_json):
        cg_paths = load_cg_paths_from_audit(args.audit_json, args.min_cd_l1, args.val_only)
    else:
        raise SystemExit("Need --cg-list, --all-backfill-list, or --audit-json")

    backup_root = os.path.join(args.recon_root, "_bad_recon_backup")
    recon_paths: list[str] = []
    applied: list[dict] = []
    skipped: list[dict] = []

    for cg_path in cg_paths:
        recon_path = recon_path_from_cg(cg_path, args.recon_root)
        entry = {"cg_path": cg_path, "recon_path": recon_path}
        if not os.path.isfile(cg_path):
            entry["reason"] = "missing_official_cg"
            skipped.append(entry)
            continue
        if not os.path.isfile(recon_path):
            entry["reason"] = "missing_recon_dst"
            skipped.append(entry)
            continue

        rel = os.path.relpath(recon_path, args.recon_root)
        backup_path = os.path.join(backup_root, rel)
        if args.dry_run:
            applied.append({**entry, "backup_path": backup_path, "dry_run": True})
            recon_paths.append(recon_path)
            continue

        os.makedirs(os.path.dirname(backup_path), exist_ok=True)
        if not os.path.isfile(backup_path):
            shutil.copy2(recon_path, backup_path)
        shutil.copy2(cg_path, recon_path)
        applied.append({**entry, "backup_path": backup_path})
        recon_paths.append(recon_path)

    list_out = args.out_json.replace(".json", "_recon_list.txt")
    if not args.dry_run and recon_paths:
        os.makedirs(os.path.dirname(list_out) or ".", exist_ok=True)
        with open(list_out, "w", encoding="utf-8") as f:
            f.write("\n".join(recon_paths) + "\n")

    report = {
        "generated_at": datetime.utcnow().isoformat() + "Z",
        "recon_root": args.recon_root,
        "num_requested": len(cg_paths),
        "num_applied": len(applied),
        "num_skipped": len(skipped),
        "val_only": args.val_only,
        "min_cd_l1": args.min_cd_l1,
        "recon_list": list_out if recon_paths else None,
        "applied": applied,
        "skipped": skipped[:20],
    }
    os.makedirs(os.path.dirname(args.out_json) or ".", exist_ok=True)
    with open(args.out_json, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)

    print(json.dumps({k: report[k] for k in ("num_requested", "num_applied", "num_skipped", "recon_list")}, indent=2))
    print(f"Written: {args.out_json}")


if __name__ == "__main__":
    main()
