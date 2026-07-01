#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${SRC:-$ROOT/output/ft_val565_fusion/holefill_lite_fill0.25_max10pct_adaptive_post25}"
DEST="${DEST:-$ROOT/output/holefill_lite_candidate}"
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
cd = None
if os.path.isfile(ev):
    d = json.load(open(ev))
    s = d.get("summary", d)
    cd = float(s["means"]["chamfer_distance"])
manifest = {
    "published": time.strftime("%Y-%m-%d %H:%M:%S"),
    "label": "holefill_lite_hybrid_val565",
    "description": "ft PD-LTS primary + SuperPC CG-hole fill lite (max10pct, adaptive post-SOR)",
    "symlink": "$DEST",
    "source_dir": src,
    "frames": 565,
    "preset": "holefill_lite_fill0.25_max10pct_adaptive_post25",
    "pipeline": {
        "pdlts_finetune_ckpt": "$CKPT",
        "geometry_primary": "output/pdlts_finetune_uvg/val565/light",
        "geometry_secondary": "output/submission_candidate",
    },
    "eval": {"chamfer_mm": cd, "json": ev},
    "vs_ft_density_mm": 14.8831,
}
out = os.path.join("$DEST", "manifest.json")
json.dump(manifest, open(out, "w"), indent=2)
print(json.dumps(manifest, indent=2))
PY
