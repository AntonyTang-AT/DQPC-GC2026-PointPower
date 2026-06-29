#!/usr/bin/env bash
set -euo pipefail
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SRC_DIR}/common.sh"

OUT="${OUT_DIR:-${GC2026_ROOT}/output/submission_candidate_pdlts_density}"
GATE_JSON="${SUBMISSION_ROOT}/config/gate_decision.json"
VAL_PAIRS="${UVG_VAL_PAIRS_FILE}"

n=$(find "$OUT" -name '*.ply' 2>/dev/null | wc -l)
echo "[post] ply_count=$n"

"$PYTHON" "${SRC_DIR}/write_runtime_summary.py" --out-dir "$OUT" --team "GC2026 Team" || true
"$PYTHON" "${SRC_DIR}/make_submission.py" \
  --enhanced-dir "$OUT" \
  --team "GC2026 Team" \
  --processing-track "Enhancement Only" \
  --title "UVG-CWI-DQPC GC2026 Enhancement Only PD-LTS density" \
  --post-processing "$GATE_JSON" \
  --cg-version "${UVG_CG_VERSION:-v2}" \
  --cg-source "official" \
  --data-split "official_val=TrumanShow,VictoryHeart,VirtualLife" \
  --pipeline-notes "Official CGv2 -> PD-LTS light -> snap 1mm + density_adaptive fill 0.6mm"

if [[ -f "$VAL_PAIRS" ]]; then
  "$PYTHON" "${SRC_DIR}/evaluate_gc_baseline_metrics.py" \
    --pairs-file "$VAL_PAIRS" \
    --test-root "$OUT" \
    --test-mode enh \
    --out-json "${OUT}/evaluation_gc_baseline_val565.json" \
    --also-cg || true
fi
echo "[post] DONE"
