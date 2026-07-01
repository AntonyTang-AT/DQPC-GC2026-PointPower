#!/usr/bin/env python3
"""Apply gate winner to full dataset, or rollback to CG passthrough."""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GC2026_ROOT = os.path.dirname(SCRIPT_DIR)
DEFAULT_GATE = os.path.join(
    GC2026_ROOT, "output", "enh_refine_p0_p1_p2", "gate_decision.json"
)

sys.path.insert(0, SCRIPT_DIR)
from enh_refine_config import ROLLBACK_CONFIG  # noqa: E402


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--gate-json", default=DEFAULT_GATE)
    p.add_argument("--cg-list", default=os.path.join(GC2026_ROOT, "data/processed/all_cg_only_cgv2.txt"))
    p.add_argument("--out-dir", default=os.path.join(GC2026_ROOT, "output", "enh_refine_production"))
    p.add_argument("--geometry-dir", default="", help="Optional cached PD-LTS root")
    p.add_argument("--rollback-only", action="store_true")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--temporal-smooth", action="store_true", help="Apply temporal XYZ smooth after infer")
    p.add_argument("--temporal-window", type=int, default=5)
    p.add_argument("--temporal-mode", choices=("mean", "ema"), default="mean")
    p.add_argument("--temporal-out-dir", default="", help="If set, write smoothed PLY here; else in-place on out-dir")
    args = p.parse_args()

    cfg_path = os.path.join(args.out_dir, "_apply_config.json")
    os.makedirs(args.out_dir, exist_ok=True)

    if args.rollback_only:
        cfg = ROLLBACK_CONFIG.to_dict()
        with open(cfg_path, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=2)
    else:
        if not os.path.isfile(args.gate_json):
            raise SystemExit(f"Missing gate: {args.gate_json}")
        with open(args.gate_json, encoding="utf-8") as f:
            gate = json.load(f)
        config_key = "production_config" if gate.get("gate_passed") else "rollback_config"
        print(f"[apply] gate_passed={gate.get('gate_passed')} using {config_key}")
        cfg = gate.get(config_key, gate.get("rollback_config"))
        with open(cfg_path, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=2)

    cmd = [
        sys.executable,
        os.path.join(SCRIPT_DIR, "run_enh_refine_infer.py"),
        "--cg-list", args.cg_list,
        "--out-dir", args.out_dir,
        "--config-json", cfg_path,
    ]
    per_seq = os.path.join(os.path.dirname(args.gate_json), "per_sequence_refine_config.json")
    if not args.rollback_only and os.path.isfile(per_seq):
        cmd.extend(["--per-seq-config", per_seq])
        print(f"[apply] per-seq-config {per_seq}")
    frame_proxy = os.path.join(os.path.dirname(args.gate_json), "frame_decision", "proxy_rules.json")
    alt_proxy = os.path.join(GC2026_ROOT, "output/enh_refine_p0_p1_p2/frame_decision/proxy_rules.json")
    for fp in (frame_proxy, alt_proxy):
        if not args.rollback_only and os.path.isfile(fp):
            cmd.extend(["--frame-proxy-json", fp])
            print(f"[apply] frame-proxy {fp}")
            break
    if args.geometry_dir:
        cmd.extend(["--geometry-dir", args.geometry_dir, "--use-geometry-cache"])

    print(" ".join(cmd))
    if not args.dry_run:
        subprocess.check_call(cmd)

    if args.temporal_smooth and not args.rollback_only:
        temporal_out = args.temporal_out_dir or args.out_dir
        cg_root = os.path.join(os.path.dirname(SCRIPT_DIR), "data/raw/UVG-CWI-DQPC")
        tcmd = [
            sys.executable,
            os.path.join(SCRIPT_DIR, "run_enh_temporal_smooth.py"),
            "--in-dir", args.out_dir,
            "--out-dir", temporal_out,
            "--window", str(args.temporal_window),
            "--mode", args.temporal_mode,
            "--cg-root", cg_root,
        ]
        if not args.temporal_out_dir:
            tcmd.append("--in-place")
        print("[apply] temporal:", " ".join(tcmd))
        if not args.dry_run:
            subprocess.check_call(tcmd)


if __name__ == "__main__":
    main()
