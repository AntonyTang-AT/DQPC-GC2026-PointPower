#!/usr/bin/env bash
# Launch val565 selection jobs in parallel (temporal CPU + infer GPU).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRID="${GRID_ROOT:-$ROOT/output/enh_refine_val565_selection}"
DENSITY_SRC="$ROOT/output/enh_refine_p0_p1_p2/pdlts_light_snap1_fill0.6_density"
LOGDIR="$GRID/logs"
mkdir -p "$LOGDIR"

source /root/miniconda3/etc/profile.d/conda.sh
conda activate superpc
export PYTHONPATH="$ROOT/scripts:${PYTHONPATH:-}"
export OPENBLAS_NUM_THREADS="${OPENBLAS_NUM_THREADS:-4}"
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-4}"
export EVAL_WORKERS="${EVAL_WORKERS:-16}"

run_temporal() {
  local win="$1"
  local name="density_temporal_w${win}"
  local out="$GRID/$name"
  local log="$LOGDIR/${name}.log"
  if [[ -f "$out/evaluation_gc_baseline_val565.json" ]]; then
    echo "[skip] $name eval done"
    return 0
  fi
  echo "[start] temporal w=$win -> $log"
  {
    rm -rf "$out"
    TEMPORAL_WINDOW="$win" EVAL=1 bash "$ROOT/scripts/run_enh_cpu_post.sh" \
      "$DENSITY_SRC" "$out"
    echo "[done] $name"
  } > "$log" 2>&1
}

run_infer_eval() {
  local preset="$1"
  local gpu="$2"
  local out="$GRID/$preset"
  local log="$LOGDIR/${preset}.log"
  if [[ -f "$out/evaluation_gc_baseline_val565.json" ]]; then
    echo "[skip] $preset eval done"
    return 0
  fi
  echo "[start] infer $preset GPU=$gpu -> $log"
  {
    CUDA_VISIBLE_DEVICES="$gpu" STAGE=infer PRESET="$preset" GPUS="$gpu" \
      bash "$ROOT/scripts/run_val565_selection.sh"
    echo "[done] $preset"
  } > "$log" 2>&1
}

PIDS=()

# temporal w3 + w5 in parallel
for w in 3 5; do
  run_temporal "$w" &
  PIDS+=($!)
done

# infer x3 on GPU 0,1,2
run_infer_eval hybrid_pdlts_superpc_snap1_fill0.6_density 0 &
PIDS+=($!)
run_infer_eval hybrid_pdlts_superpc_snap1_fill0.6_superfill 1 &
PIDS+=($!)
run_infer_eval fp_migrated_pre25_density 2 &
PIDS+=($!)

echo "[parallel] launched ${#PIDS[@]} jobs (2 temporal + 3 infer)"
echo "[parallel] logs -> $LOGDIR"
echo "[parallel] monitor: bash scripts/monitor_val565_selection.sh"

FAIL=0
for pid in "${PIDS[@]}"; do
  wait "$pid" || FAIL=1
done

if [[ "$FAIL" -ne 0 ]]; then
  echo "[parallel] one or more jobs failed — check $LOGDIR"
  exit 1
fi
echo "[parallel] all jobs finished"
