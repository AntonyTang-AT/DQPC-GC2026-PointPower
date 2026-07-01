#!/usr/bin/env bash
# Run official GC baseline metrics (aligned CG/ENH vs HE) for Enhancement Only.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GC2026_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-2}"

ENH_ROOT="${1:-${GC2026_ROOT}/output/submission_candidate}"
PAIRS="${UVG_VAL_PAIRS_FILE:-${GC2026_ROOT}/data/processed/val_pairs_official_cgv2.txt}"
WORKERS="${GC_METRIC_WORKERS:-8}"
TAG="${2:-val565}"

OUT_JSON="${ENH_ROOT}/evaluation_gc_baseline_enh_${TAG}.json"
OUT_CSV="${ENH_ROOT}/evaluation_gc_baseline_enh_${TAG}.csv"
BASELINE="${GC2026_ROOT}/ACMMM26_GC_baseline.csv"

python3.12 "${SCRIPT_DIR}/evaluate_gc_baseline_metrics.py" \
  --pairs-file "${PAIRS}" \
  --test-root "${ENH_ROOT}" \
  --test-mode enh \
  --workers "${WORKERS}" \
  --out-json "${OUT_JSON}" \
  --out-csv "${OUT_CSV}"

python3.12 "${SCRIPT_DIR}/compare_enh_to_baseline.py" \
  --baseline-csv "${BASELINE}" \
  --enh-csv "${OUT_CSV}" \
  --out-json "${ENH_ROOT}/evaluation_gc_baseline_enh_${TAG}_vs_baseline.json"

echo "Done: ${OUT_JSON}"
