#!/usr/bin/env bash
# Full Pipeline: official aligned GC baseline metrics + compare to ACMMM26_GC_baseline.csv
#
# Usage:
#   bash scripts/run_full_pipeline_gc_baseline_metrics.sh           # val565 + all2155
#   bash scripts/run_full_pipeline_gc_baseline_metrics.sh val565    # val only
#   nohup bash scripts/run_full_pipeline_gc_baseline_metrics.sh >> output/full_pipeline_gc_baseline_eval.log 2>&1 &
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GC2026_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-2}"

ENH_ROOT="${ENH_ROOT:-${GC2026_ROOT}/output/full_pipeline_n0_v2_candidate}"
RECON_ROOT="${RECON_ROOT:-${GC2026_ROOT}/output/full_pipeline_n0_v2_cg}"
WORKERS="${GC_METRIC_WORKERS:-8}"
BASELINE="${GC2026_ROOT}/ACMMM26_GC_baseline.csv"
SCOPE="${1:-val565}"

VAL_PAIRS="${RECON_ROOT}/recon_he_pairs_official_val565.txt"
ALL_LIST="${RECON_ROOT}/reconstructed_cg_list.txt"
LOG="${GC2026_ROOT}/output/full_pipeline_gc_baseline_eval.log"

log() { echo "[$(date -Iseconds)] $*"; }

run_scope() {
  local tag="$1" pairs_file="$2"
  local out_json="${ENH_ROOT}/evaluation_gc_baseline_fp_${tag}.json"
  local out_csv="${ENH_ROOT}/evaluation_gc_baseline_fp_${tag}.csv"
  local vs_json="${ENH_ROOT}/evaluation_gc_baseline_fp_${tag}_vs_baseline.json"
  local per_seq="${ENH_ROOT}/per_sequence_gc_baseline_fp_${tag}.json"

  log "=== Full Pipeline GC metric: ${tag} (workers=${WORKERS}) ==="
  python3.12 "${SCRIPT_DIR}/evaluate_full_pipeline_gc_baseline_metrics.py" \
    --pairs-file "${pairs_file}" \
    --recon-list "${ALL_LIST}" \
    --enhanced-root "${ENH_ROOT}" \
    --workers "${WORKERS}" \
    --out-json "${out_json}" \
    --out-csv "${out_csv}"

  python3.12 "${SCRIPT_DIR}/compare_enh_to_baseline.py" \
    --baseline-csv "${BASELINE}" \
    --enh-csv "${out_csv}" \
    --out-json "${vs_json}"

  python3.12 "${SCRIPT_DIR}/summarize_gc_baseline_by_sequence.py" \
    --eval-json "${out_json}" \
    --out-json "${per_seq}"

  log "Done ${tag}: ${out_json}"
  log "  vs baseline: ${vs_json}"
}

case "${SCOPE}" in
  val565)
    run_scope "val565" "${VAL_PAIRS}"
    ;;
  all2155|all)
    if [[ "${SCOPE}" == "all" ]]; then
      run_scope "val565" "${VAL_PAIRS}"
    fi
    run_scope "all2155" "${ALL_LIST}"
    ;;
  *)
    echo "Unknown scope: ${SCOPE} (use val565 | all2155 | all)"
    exit 1
    ;;
esac

log "ALL COMPLETE — see ${ENH_ROOT}/evaluation_gc_baseline_fp_*"
