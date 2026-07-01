#!/usr/bin/env python3
"""P0 Stage1 audit: official val565 recon vs official CG/HE, backfill + outlier cross-ref."""
from __future__ import annotations

import argparse
import gc
import json
import os
import sys
from collections import defaultdict
from datetime import datetime

import numpy as np
from tqdm import tqdm

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GC2026_ROOT = os.path.dirname(SCRIPT_DIR)
sys.path.insert(0, SCRIPT_DIR)

from compare_reconstructed_cg import recon_path_from_cg  # noqa: E402
from evaluate_uvg import chamfer_symmetric_kdtree  # noqa: E402
from uvg_io import parse_frame_id, read_ply_xyz  # noqa: E402


def seq_from_cg(cg: str) -> str:
    return cg.split("/UVG-CWI-DQPC/")[1].split("/")[0]


def load_backfill_set(path: str) -> set[str]:
    if not os.path.isfile(path):
        return set()
    out = set()
    for ln in open(path, encoding="utf-8"):
        ln = ln.strip()
        if ln and not ln.startswith("#"):
            out.add(ln)
    return out


def load_enh_eval(path: str) -> dict[str, dict]:
    if not os.path.isfile(path):
        return {}
    data = json.load(open(path, encoding="utf-8"))
    by_cg = {}
    for r in data.get("records", []):
        by_cg[r["cg_path"]] = r
    return by_cg


def summarize_seq(rows: list[dict], key: str) -> dict:
    vals = [r[key] for r in rows if r.get(key) is not None]
    if not vals:
        return {"n": 0}
    a = np.array(vals)
    return {
        "n": len(vals),
        "mean": float(a.mean()),
        "p50": float(np.median(a)),
        "p90": float(np.percentile(a, 90)),
        "max": float(a.max()),
    }


def main() -> None:
    p = argparse.ArgumentParser(description="Stage1 P0 audit on official val565")
    p.add_argument(
        "--recon-root",
        default=os.path.join(GC2026_ROOT, "output/full_pipeline_n0_v2_cg"),
    )
    p.add_argument(
        "--pairs-file",
        default=os.path.join(GC2026_ROOT, "data/processed/val_pairs_official_cgv2.txt"),
    )
    p.add_argument(
        "--backfill-list",
        default=os.path.join(GC2026_ROOT, "output/full_pipeline_n0_v2_cg/_retry_missing.txt"),
    )
    p.add_argument(
        "--full-enh-eval",
        default=os.path.join(
            GC2026_ROOT, "output/full_pipeline_n0_v2_candidate/evaluation_official_val_n20k.json"
        ),
    )
    p.add_argument(
        "--n-samples",
        type=int,
        default=5000,
        help="Chamfer subsample count (KDTree backend, safe under 2GB cgroup)",
    )
    p.add_argument("--max-load-points", type=int, default=40000)
    p.add_argument(
        "--out-json",
        default=os.path.join(GC2026_ROOT, "output/stage1_p0_audit.json"),
    )
    args = p.parse_args()

    backfill = load_backfill_set(args.backfill_list)
    enh_by_cg = load_enh_eval(args.full_enh_eval)

    lines = [ln.strip() for ln in open(args.pairs_file, encoding="utf-8") if ln.strip()]
    rng = np.random.RandomState(21)
    records = []
    missing_recon = []
    missing_he = []

    for line in tqdm(lines, desc="stage1_p0"):
        parts = line.split("\t")
        if len(parts) < 2 or not parts[1].strip():
            missing_he.append(parts[0] if parts else line)
            continue
        cg_path, he_path = parts[0], parts[1]
        recon_path = recon_path_from_cg(cg_path, args.recon_root)
        if not os.path.isfile(recon_path):
            missing_recon.append(cg_path)
            continue
        if not os.path.isfile(he_path):
            missing_he.append(cg_path)
            continue

        off_xyz = read_ply_xyz(cg_path, max_points=args.max_load_points, rng=rng)
        rec_xyz = read_ply_xyz(recon_path, max_points=args.max_load_points, rng=rng)
        he_xyz = read_ply_xyz(he_path, max_points=args.max_load_points, rng=rng)

        m_ro = chamfer_symmetric_kdtree(rec_xyz, off_xyz, args.n_samples, rng)
        m_rh = chamfer_symmetric_kdtree(rec_xyz, he_xyz, args.n_samples, rng)
        n_recon = int(rec_xyz.shape[0])
        n_official = int(off_xyz.shape[0])
        point_ratio = float(n_recon / max(n_official, 1))
        del off_xyz, rec_xyz, he_xyz
        gc.collect()

        fid = parse_frame_id(cg_path)
        seq = seq_from_cg(cg_path)
        is_backfill = cg_path in backfill
        enh = enh_by_cg.get(cg_path, {})
        enh_cd = enh.get("enh_cd_l1")
        cg_he = enh.get("cg_cd_l1")
        enh_imp = (cg_he - enh_cd) if (cg_he is not None and enh_cd is not None) else None

        records.append(
            {
                "sequence": seq,
                "frame_id": fid,
                "cg_path": cg_path,
                "recon_path": recon_path,
                "he_path": he_path,
                "recon_vs_official_cg_cd_l1": m_ro["cd_l1"],
                "recon_vs_he_cd_l1": m_rh["cd_l1"],
                "official_cg_vs_he_cd_l1": cg_he,
                "full_enh_vs_he_cd_l1": enh_cd,
                "full_enh_improvement_vs_cg": enh_imp,
                "n_recon": n_recon,
                "n_official": n_official,
                "point_ratio": point_ratio,
                "is_backfill_candidate": is_backfill,
            }
        )

    by_seq: dict[str, list[dict]] = defaultdict(list)
    for r in records:
        by_seq[r["sequence"]].append(r)

    per_sequence = {}
    for seq in sorted(by_seq):
        rows = by_seq[seq]
        bf = [r for r in rows if r["is_backfill_candidate"]]
        non_bf = [r for r in rows if not r["is_backfill_candidate"]]
        per_sequence[seq] = {
            "num_frames": len(rows),
            "num_backfill_candidates": len(bf),
            "recon_vs_official_cg": summarize_seq(rows, "recon_vs_official_cg_cd_l1"),
            "recon_vs_he": summarize_seq(rows, "recon_vs_he_cd_l1"),
            "official_cg_vs_he": summarize_seq(rows, "official_cg_vs_he_cd_l1"),
            "full_enh_vs_he": summarize_seq(rows, "full_enh_vs_he_cd_l1"),
            "backfill_recon_vs_official_cg": summarize_seq(bf, "recon_vs_official_cg_cd_l1"),
            "non_backfill_recon_vs_official_cg": summarize_seq(non_bf, "recon_vs_official_cg_cd_l1"),
        }

    # Outliers
    def top_k(key: str, k: int = 10) -> list[dict]:
        ranked = sorted(records, key=lambda r: r[key], reverse=True)
        return [
            {
                "sequence": r["sequence"],
                "frame_id": r["frame_id"],
                key: r[key],
                "is_backfill_candidate": r["is_backfill_candidate"],
                "full_enh_vs_he_cd_l1": r.get("full_enh_vs_he_cd_l1"),
            }
            for r in ranked[:k]
        ]

    backfill_rows = [r for r in records if r["is_backfill_candidate"]]
    non_backfill_rows = [r for r in records if not r["is_backfill_candidate"]]

    overall = {
        "num_pairs": len(lines),
        "num_evaluated": len(records),
        "missing_recon": len(missing_recon),
        "missing_he": len(missing_he),
        "num_backfill_candidates_in_val": len(backfill_rows),
        "recon_vs_official_cg_cd_l1_mean": float(
            np.mean([r["recon_vs_official_cg_cd_l1"] for r in records])
        ),
        "recon_vs_he_cd_l1_mean": float(np.mean([r["recon_vs_he_cd_l1"] for r in records])),
        "official_cg_vs_he_cd_l1_mean": float(
            np.mean([r["official_cg_vs_he_cd_l1"] for r in records if r["official_cg_vs_he_cd_l1"]])
        ),
        "backfill_recon_vs_official_cg_mean": float(
            np.mean([r["recon_vs_official_cg_cd_l1"] for r in backfill_rows])
        )
        if backfill_rows
        else None,
        "non_backfill_recon_vs_official_cg_mean": float(
            np.mean([r["recon_vs_official_cg_cd_l1"] for r in non_backfill_rows])
        )
        if non_backfill_rows
        else None,
    }

    # Full ENH outliers linked to stage1
    enh_outliers = sorted(
        [r for r in records if r.get("full_enh_vs_he_cd_l1")],
        key=lambda r: r["full_enh_vs_he_cd_l1"],
        reverse=True,
    )[:15]

    out = {
        "generated_at": datetime.utcnow().isoformat() + "Z",
        "recon_root": args.recon_root,
        "pairs_file": args.pairs_file,
        "n_samples": args.n_samples,
        "overall": overall,
        "per_sequence": per_sequence,
        "backfill_audit": {
            "list_path": args.backfill_list,
            "total_listed": len(backfill),
            "in_official_val": len(backfill_rows),
            "by_sequence": {
                seq: sum(1 for r in backfill_rows if r["sequence"] == seq)
                for seq in sorted({r["sequence"] for r in backfill_rows})
            },
            "frames": [
                {
                    "sequence": r["sequence"],
                    "frame_id": r["frame_id"],
                    "recon_vs_official_cg_cd_l1": r["recon_vs_official_cg_cd_l1"],
                    "recon_vs_he_cd_l1": r["recon_vs_he_cd_l1"],
                    "full_enh_vs_he_cd_l1": r.get("full_enh_vs_he_cd_l1"),
                }
                for r in sorted(backfill_rows, key=lambda x: x["recon_vs_official_cg_cd_l1"], reverse=True)
            ],
        },
        "worst_recon_vs_official_cg": top_k("recon_vs_official_cg_cd_l1", 15),
        "worst_recon_vs_he": top_k("recon_vs_he_cd_l1", 15),
        "worst_full_enh_vs_he": [
            {
                "sequence": r["sequence"],
                "frame_id": r["frame_id"],
                "full_enh_vs_he_cd_l1": r["full_enh_vs_he_cd_l1"],
                "recon_vs_official_cg_cd_l1": r["recon_vs_official_cg_cd_l1"],
                "is_backfill_candidate": r["is_backfill_candidate"],
            }
            for r in enh_outliers
        ],
        "missing_recon_sample": missing_recon[:10],
        "records": records,
    }

    os.makedirs(os.path.dirname(args.out_json) or ".", exist_ok=True)
    with open(args.out_json, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2)

    # Compact summary for stdout
    summary = {
        "overall": overall,
        "per_sequence_means": {
            seq: {
                "recon_vs_official_cg": v["recon_vs_official_cg"]["mean"],
                "recon_vs_he": v["recon_vs_he"]["mean"],
                "official_cg_vs_he": v["official_cg_vs_he"]["mean"],
                "full_enh_vs_he": v["full_enh_vs_he"]["mean"],
                "backfill_n": v["num_backfill_candidates"],
            }
            for seq, v in per_sequence.items()
        },
    }
    summary_path = args.out_json.replace(".json", "_summary.json")
    with open(summary_path, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)

    print(json.dumps(summary, indent=2))
    print(f"Written: {args.out_json}")
    print(f"Written: {summary_path}")


if __name__ == "__main__":
    main()
