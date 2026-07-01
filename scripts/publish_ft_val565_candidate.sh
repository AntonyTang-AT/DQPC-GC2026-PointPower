#!/usr/bin/env bash
# Publish verified fine-tune val565 ENH (density preset) as canonical candidate.
#
#   bash scripts/publish_ft_val565_candidate.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${SRC:-$ROOT/output/pdlts_finetune_uvg/val565_refine/pdlts_light_snap1_fill0.6_density}"
DEST="${DEST:-$ROOT/output/ft_val565_candidate}"
CKPT="${CKPT:-$(ls -t "$ROOT/output/pdlts_finetune_uvg"/run_*/DenoiseFlow-light-UVG-finetune.ckpt 2>/dev/null | head -1)}"

n=$(find "$SRC" -name '*.ply' 2>/dev/null | wc -l)
[[ "$n" -ge 565 ]] || { echo "blocked: $SRC has ${n}/565 ply" >&2; exit 1; }

mkdir -p "$(dirname "$DEST")"
ln -sfn "$SRC" "$DEST"

source /root/miniconda3/etc/profile.d/conda.sh
conda activate superpc 2>/dev/null || true
python3 - <<PY
import json, os, time
root = "$ROOT"
dest = "$DEST"
src = os.path.realpath("$SRC")
ckpt = "$CKPT"
ev = os.path.join(src, "evaluation_gc_baseline_val565.json")
cd = None
if os.path.isfile(ev):
    d = json.load(open(ev))
    s = d.get("summary", d)
    cd = float((s.get("means") or {}).get("chamfer_distance") or s.get("mean_enh_chamfer_distance"))
manifest = {
    "published": time.strftime("%Y-%m-%d %H:%M:%S"),
    "label": "pdlts_finetune_uvg_val565_density",
    "description": "Fine-tune PD-LTS light ckpt + snap1/fill0.6/density (correct ft effect ENH)",
    "symlink": dest,
    "source_dir": src,
    "frames": 565,
    "sequences": ["TrumanShow", "VictoryHeart", "VirtualLife"],
    "pipeline": {
        "pdlts_ckpt": ckpt,
        "pdlts_infer": "output/pdlts_finetune_uvg/val565/light",
        "refine_preset": "pdlts_light_snap1_fill0.6_density",
    },
    "eval": {
        "chamfer_mm": cd,
        "json": ev if os.path.isfile(ev) else None,
    },
    "not_fusion": "Do NOT use ft_val565_fusion/* — region hybrid output equals frozen (~16.502 mm).",
}
out = os.path.join(dest, "manifest.json")
json.dump(manifest, open(out, "w"), indent=2)
print(json.dumps(manifest, indent=2))
print(f"\n-> {out}")
PY

echo "[publish] $DEST -> $(readlink -f "$DEST")"
