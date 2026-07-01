#!/usr/bin/env bash
# Low-CPU fusion eval while PD-LTS GPU training runs (sequential, nice priority).
#
#   bash scripts/run_fusion_eval_lowcpu.sh          # foreground
#   bash scripts/run_fusion_eval_lowcpu.sh bg       # background
#
# Env:
#   FUSION_CPU_BUDGET=12   eval worker count (default 12)
#   NICE_LEVEL=15          lower = higher priority to training (default 15)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRID="${GRID_ROOT:-$ROOT/output/enh_refine_val565_selection}"
LOGDIR="$GRID/logs/region_hybrid"
FUSION_CPU_BUDGET="${FUSION_CPU_BUDGET:-12}"
NICE_LEVEL="${NICE_LEVEL:-15}"
mkdir -p "$LOGDIR"

PRESETS=(
  region_hybrid_pdlts_superpc_snap1_fill0.6_density
  temporal_region_hybrid_pdlts_superpc_snap1_fill0.6_density
)

run_all() {
  echo "[fusion-lowcpu] budget=$FUSION_CPU_BUDGET workers nice=$NICE_LEVEL nproc=$(nproc)"
  for preset in "${PRESETS[@]}"; do
    local out="$GRID/$preset"
    local ev="$out/evaluation_gc_baseline_val565.json"
    local nply
    nply=$(find "$out" -name '*.ply' 2>/dev/null | wc -l)
    if [[ "$nply" -lt 565 ]]; then
      echo "[fusion-lowcpu] skip $preset — infer incomplete ($nply/565)"
      continue
    fi
    if [[ -f "$ev" ]]; then
      echo "[fusion-lowcpu] skip $preset — eval exists"
      continue
    fi
    echo "[fusion-lowcpu] eval $preset ($nply/565 PLY) workers=$FUSION_CPU_BUDGET"
    nice -n "$NICE_LEVEL" env \
      PRESET="$preset" OUT_DIR="$out" SKIP_INFER=1 \
      EVAL_WORKERS="$FUSION_CPU_BUDGET" MAX_EVAL_WORKERS="$FUSION_CPU_BUDGET" \
      OMP_THREADS_PER_WORKER=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1 \
      bash "$ROOT/scripts/run_region_hybrid_val565.sh" eval-only
  done
  bash "$ROOT/scripts/show_region_hybrid_progress.sh"
}

case "${1:-}" in
  bg)
    log="$LOGDIR/fusion_eval_lowcpu.log"
    nohup bash "$0" >> "$log" 2>&1 &
    echo "[fusion-lowcpu] pid=$! log=$log budget=$FUSION_CPU_BUDGET"
    ;;
  *)
    run_all
    ;;
esac
