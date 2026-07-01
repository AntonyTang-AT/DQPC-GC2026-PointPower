#!/usr/bin/env bash
# Keep 7 canonical PNGs; remove superseded / duplicate outputs.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/docs/meeting_delivery/figures}"
TAG="VirtualLife_431_VirtualLife_UVG-CWI-DQPC_ENH_15_0_195_0063"

pick() {
  local pattern="$1"
  local f
  f=$(ls -1 "$OUT"/$pattern 2>/dev/null | head -1 || true)
  [[ -n "$f" ]] || return 1
  echo "$f"
}

mv_if() {
  local src="$1" dst="$2"
  [[ -f "$src" ]] || return 0
  mv -f "$src" "$dst"
}

# Rename latest outputs -> canonical names
mv_if "$(pick "qualitative_${TAG}.png")" "$OUT/01_overview_qualitative.png"
mv_if "$(pick "dual_reference_${TAG}.png")" "$OUT/02_dual_reference.png"
mv_if "$(pick "zoom_highlight_cg_${TAG}.png")" "$OUT/03_zoom_cg_fidelity.png"
mv_if "$OUT/bar_per_sequence_chamfer.png" "$OUT/04_chart_per_sequence.png"
mv_if "$OUT/bar_accuracy_completeness.png" "$OUT/05_chart_acc_comp.png"
mv_if "$OUT/curve_superpc_minus_density.png" "$OUT/06_chart_frame_diff.png"
mv_if "$OUT/diagram_pipeline_pdlts_density.png" "$OUT/07_diagram_pipeline.png"

# Remove superseded PNGs (old zoom / heatmap / duplicate ablations)
shopt -s nullglob
for f in "$OUT"/*.png; do
  base=$(basename "$f")
  case "$base" in
    0[1-7]_*.png) continue ;;
    meta.json) continue ;;
  esac
  rm -f "$f"
done

# Refresh meta.json from qualitative + zoom cg sources before deleting other JSON
QUAL="$OUT/qualitative_${TAG}.json"
ZCG="$OUT/zoom_highlight_cg_${TAG}.json"
python3 - <<PY
import json
from pathlib import Path
out = Path("$OUT")
meta_path = out / "meta.json"
meta = json.loads(meta_path.read_text(encoding="utf-8")) if meta_path.is_file() else {"figures": []}
qp = Path("$QUAL")
if qp.is_file():
    q = json.loads(qp.read_text(encoding="utf-8"))
    meta["frame"] = {
        "sequence": q["sequence"],
        "frame_index_val565": q["frame_index_val565"],
        "enh_filename": q["enh_filename"],
        "cg_filename": q["cg_filename"],
        "he_filename": q["he_filename"],
        "chamfer_mm": q.get("chamfer_mm", {}),
        "gap_superpc_minus_vh_mm": q.get("gap_superpc_minus_vh"),
        "view": q.get("view", {}),
    }
zp = Path("$ZCG")
if zp.is_file():
    z = json.loads(zp.read_text(encoding="utf-8"))
    rois = []
    for i, r in enumerate(z.get("rois", [])):
        rois.append({
            "label": chr(ord("A") + i),
            "mean_sp_cg_mm": round(r.get("mean_sp_cg_mm", 0), 2),
            "mean_density_cg_mm": round(r.get("mean_ref_cg_mm", 0), 2),
            "mean_cg_gap_mm": round(r.get("mean_cg_gap_mm", 0), 2),
        })
    if rois:
        meta["cg_fidelity_rois"] = rois
meta_path.write_text(json.dumps(meta, indent=2), encoding="utf-8")
PY

# Remove stray JSON (keep meta.json only)
for f in "$OUT"/*.json; do
  [[ "$(basename "$f")" == "meta.json" ]] && continue
  rm -f "$f"
done

rm -rf "$OUT/.ipynb_checkpoints"

echo "[consolidate] kept:"
ls -1 "$OUT"/*.png 2>/dev/null || true
