#!/usr/bin/env bash
# After fast grid: winner vs baseline + MORNING_REPORT.md
set -euo pipefail

GC2026_ROOT="/root/autodl-tmp/GC2026"
GRID_ROOT="${GC2026_ROOT}/output/val_grid_official565"
GATE_JSON="${GRID_ROOT}/gate_decision.json"
BASELINE="${GC2026_ROOT}/ACMMM26_GC_baseline.csv"

log() { echo "[$(date -Iseconds)] [finalize] $*"; }

if [[ ! -f "$GATE_JSON" ]]; then
  log "ERROR: missing $GATE_JSON — run grid first"
  exit 1
fi

WINNER=$(python3.12 -c "
import json
d=json.load(open('${GATE_JSON}'))
print(d.get('best_experiment') or d.get('selected_experiment') or '')
")

if [[ -z "$WINNER" ]]; then
  log "WARN: no winner in gate_decision.json"
  python3.12 "${GC2026_ROOT}/scripts/build_morning_report.py"
  exit 0
fi

WINNER_CSV="${GRID_ROOT}/${WINNER}/evaluation_gc_baseline_val565.csv"
WINNER_VS="${GRID_ROOT}/winner_vs_baseline.json"

if [[ -f "$WINNER_CSV" ]]; then
  log "compare winner vs baseline: $WINNER"
  python3.12 "${GC2026_ROOT}/scripts/compare_enh_to_baseline.py" \
    --baseline-csv "$BASELINE" \
    --enh-csv "$WINNER_CSV" \
    --out-json "$WINNER_VS"
else
  log "WARN: missing $WINNER_CSV"
fi

python3.12 "${GC2026_ROOT}/scripts/build_morning_report.py"
log "DONE — report: ${GRID_ROOT}/MORNING_REPORT.md"
