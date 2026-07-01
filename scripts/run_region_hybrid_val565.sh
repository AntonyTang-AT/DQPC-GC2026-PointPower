#!/usr/bin/env bash
# Region-aware PD-LTS + SuperPC hybrid on **val565 only** (3 sequences, 565 frames).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=cpu_parallel_defaults.sh
source "$ROOT/scripts/cpu_parallel_defaults.sh"

MODE="${1:-val565}"
PRESET="${PRESET:-region_hybrid_pdlts_superpc_snap1_fill0.6_density}"
CG_LIST="${CG_LIST:-$ROOT/data/processed/val_cg_only_official_cgv2.txt}"
PAIRS="${PAIRS:-$ROOT/data/processed/val_pairs_official_cgv2.txt}"
GRID="${GRID_ROOT:-$ROOT/output/enh_refine_val565_selection}"
OUT_DIR="${OUT_DIR:-$GRID/$PRESET}"
GEOMETRY_DIR="${GEOMETRY_DIR:-$ROOT/output/pdlts_val565/light}"
MAX_SAMPLES="${MAX_SAMPLES:-12}"
LOGDIR="${LOGDIR:-$GRID/logs/region_hybrid}"
SKIP_INFER="${SKIP_INFER:-0}"

source /root/miniconda3/etc/profile.d/conda.sh
conda activate superpc
export PYTHONPATH="$ROOT/scripts:${PYTHONPATH:-}"

mkdir -p "$OUT_DIR" "$LOGDIR"

run_eval() {
  local out_json="$1"
  local max_frames="${2:-0}"
  local args=(
    --pairs-file "$PAIRS"
    --test-root "$OUT_DIR"
    --test-mode enh
    --out-json "$out_json"
    --also-cg
    --workers "$EVAL_WORKERS"
  )
  [[ "$max_frames" -gt 0 ]] && args+=(--max-frames "$max_frames")
  echo "[region_hybrid] eval workers=$EVAL_WORKERS -> $out_json"
  python "$ROOT/scripts/evaluate_gc_baseline_metrics.py" "${args[@]}"
}

run_smoke() {
  local n="${MAX_SAMPLES:-12}"
  echo "[region_hybrid] smoke preset=$PRESET n=$n shards=$NUM_SHARDS -> $OUT_DIR"
  python "$ROOT/scripts/run_enh_refine_infer.py" \
    --cg-list "$CG_LIST" \
    --out-dir "$OUT_DIR" \
    --preset "$PRESET" \
    --use-geometry-cache \
    --require-geometry-cache \
    --geometry-dir "$GEOMETRY_DIR" \
    --geometry-fallback filter_cg \
    --max-samples "$n" \
    --no-skip-existing
  run_eval "$OUT_DIR/evaluation_gc_baseline_val565_smoke.json" "$n"
}

run_val565() {
  if [[ "$SKIP_INFER" != "1" ]]; then
    echo "[region_hybrid] infer preset=$PRESET shards=$NUM_SHARDS -> $OUT_DIR"
    PRESET="$PRESET" OUT_DIR="$OUT_DIR" GEOMETRY_DIR="$GEOMETRY_DIR" CG_LIST="$CG_LIST" \
      LOGDIR="$LOGDIR" NUM_SHARDS="$NUM_SHARDS" \
      bash "$ROOT/scripts/run_enh_refine_sharded.sh"
  else
    echo "[region_hybrid] skip infer (SKIP_INFER=1)"
  fi
  run_eval "$OUT_DIR/evaluation_gc_baseline_val565.json"
}

case "$MODE" in
  smoke) run_smoke ;;
  val565|full) run_val565 ;;
  eval-only) run_eval "$OUT_DIR/evaluation_gc_baseline_val565.json" ;;
  *)
    echo "Usage: $0 {smoke|val565|eval-only}" >&2
    exit 1
    ;;
esac

echo "[region_hybrid] done -> $OUT_DIR"
