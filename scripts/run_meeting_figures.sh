#!/usr/bin/env bash
# Generate + consolidate val565 meeting figures (7 PNG + meta.json).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT_DIR:-$ROOT/docs/meeting_delivery/figures}"
TAG="VirtualLife_431_VirtualLife_UVG-CWI-DQPC_ENH_15_0_195_0063"
META_JSON="$OUT/meta.json"

source /root/miniconda3/etc/profile.d/conda.sh
conda activate superpc
export PYTHONPATH="$ROOT/scripts:${PYTHONPATH:-}"
mkdir -p "$OUT"

FRAME_ARGS=(--frame-meta "$OUT/meta.json")
[[ -f "$OUT/meta.json" ]] || FRAME_ARGS=()

echo "[figures] qualitative overview..."
python "$ROOT/scripts/render_val565_qualitative.py" --out-dir "$OUT" ${FRAME_ARGS:+${FRAME_ARGS[@]}}

echo "[figures] zoom CG + dual reference..."
python "$ROOT/scripts/render_val565_zoom_figures.py" --out-dir "$OUT" --figures zoom_cg,dual ${FRAME_ARGS:+${FRAME_ARGS[@]}}

echo "[figures] charts + pipeline..."
python "$ROOT/scripts/render_val565_paper_figures.py" --out-dir "$OUT" --figures bar_per_seq,acc_comp,frame_diff,pipeline

echo "[figures] consolidate..."
bash "$ROOT/scripts/consolidate_meeting_figures.sh"

MIRROR="$ROOT/output/meeting_delivery/figures"
mkdir -p "$MIRROR"
rsync -a --delete "$OUT/" "$MIRROR/"
echo "[figures] done -> $OUT (mirrored)"
