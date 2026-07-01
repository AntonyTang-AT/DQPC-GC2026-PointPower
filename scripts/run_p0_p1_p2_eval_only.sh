#!/usr/bin/env bash
# Eval-only for completed infer dirs under enh_refine_p0_p1_p2.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRID="${GRID_ROOT:-$ROOT/output/enh_refine_p0_p1_p2}"
PAIRS="$ROOT/data/processed/val_pairs_official_cgv2.txt"
EVAL_WORKERS="${EVAL_WORKERS:-12}"
PARALLEL="${PARALLEL_EVAL:-2}"

source /root/miniconda3/etc/profile.d/conda.sh
conda activate superpc
export PYTHONPATH="$ROOT/scripts:${PYTHONPATH:-}"
export OPENBLAS_NUM_THREADS="${OPENBLAS_NUM_THREADS:-1}"
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-1}"

log() { echo "[eval_only] $(date +%H:%M:%S) $*"; }

run_eval() {
  local out="$GRID/$1"
  [[ -f "$out/infer_meta.json" ]] || { log "skip eval (no infer) $1"; return 0; }
  [[ -f "$out/evaluation_gc_baseline_val565.json" ]] && { log "skip eval (done) $1"; return 0; }
  log "eval $1 workers=$EVAL_WORKERS"
  python "$ROOT/scripts/evaluate_gc_baseline_metrics.py" \
    --pairs-file "$PAIRS" --test-root "$out" --workers "$EVAL_WORKERS" \
    --also-cg \
    --out-json "$out/evaluation_gc_baseline_val565.json" \
    --out-csv "$out/evaluation_gc_baseline_val565.csv"
}

EXPS=(
  p0_perseq
  p0_perseq_rollback
  pdlts_light_snap1_fill0.6_post25
  pdlts_light_snap1_adapt
  p1_pdlts_heavy_snap1_fill0.6
  pdlts_light_snap1_fill0.6_density
  pdlts_light_snap1_fill0.6_bidir
  pdlts_light_snap1_fill0.6_combined
)

if [[ "$PARALLEL" -le 1 ]]; then
  for e in "${EXPS[@]}"; do run_eval "$e"; done
else
  active=0
  for e in "${EXPS[@]}"; do
    while (( active >= PARALLEL )); do
      wait -n 2>/dev/null && active=$((active - 1)) || { wait || true; active=0; }
    done
    run_eval "$e" &
    active=$((active + 1))
  done
  wait || true
fi

python "$ROOT/scripts/enh_refine_gate.py" --grid-root "$GRID" --out-json "$GRID/gate_decision.json"
python "$ROOT/scripts/build_per_sequence_enh_refine_config.py" \
  --grid-root "$GRID" --out-json "$GRID/per_sequence_refine_config.json"
log "DONE eval -> $GRID/gate_decision.json"
