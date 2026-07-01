#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${SRC:-$ROOT/output/ft_val565_fusion/holefill_adaptive_frame_gate_v2}"
DEST="${DEST:-$ROOT/output/frame_gate_v2_candidate}"
CKPT="${CKPT:-$(ls -t "$ROOT/output/pdlts_finetune_uvg"/run_*/DenoiseFlow-light-UVG-finetune.ckpt 2>/dev/null | head -1)}"

n=$(find "$SRC" -name '*.ply' 2>/dev/null | wc -l)
[[ "$n" -ge 565 ]] || { echo "blocked: $SRC has ${n}/565 ply" >&2; exit 1; }

mkdir -p "$(dirname "$DEST")"
ln -sfn "$SRC" "$DEST"

python3 - <<PY
import json, os, time
root = "$ROOT"
src = os.path.realpath("$SRC")
ev = os.path.join(src, "evaluation_gc_baseline_val565.json")
cd = ft = None
if os.path.isfile(ev):
    d = json.load(open(ev))
    cd = float(d["summary"]["means"]["chamfer_distance"])
ft = 14.883117568525718
manifest = {
    "published": time.strftime("%Y-%m-%d %H:%M:%S"),
    "label": "frame_gate_v2_hybrid_val565",
    "description": "ft density base + frame-level SuperPC gate (VH/VL skip, TS adaptive fill)",
    "symlink": "$DEST",
    "source_dir": src,
    "frames": int("$n"),
    "preset": "holefill_adaptive_frame_gate_v2",
    "pipeline": {
        "pdlts_finetune_ckpt": "$CKPT",
        "geometry_primary": "output/pdlts_finetune_uvg/val565/light",
        "geometry_secondary": "output/submission_candidate",
        "primary_density_refine": "snap1 + fill0.6 density (always)",
    },
    "eval": {"chamfer_mm": cd, "json": ev},
    "vs_ft_density_mm": ft,
    "delta_vs_ft_mm": (cd - ft) if cd else None,
}
out = os.path.join("$DEST", "manifest.json")
json.dump(manifest, open(out, "w"), indent=2)
print(json.dumps(manifest, indent=2))
PY
