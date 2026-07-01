#!/usr/bin/env bash
# Auto-tune shard / eval worker counts for CPU-bound refine + gc_baseline eval.
# Source from other scripts:  source "$(dirname "$0")/cpu_parallel_defaults.sh"
#
# Override examples:
#   NUM_SHARDS=16 EVAL_WORKERS=16 bash scripts/run_region_hybrid_val565.sh val565
#   PRESET_JOBS=2 bash scripts/launch_region_hybrid_val565_bg.sh  # split cores across presets
set -euo pipefail

NPROC="${NPROC:-$(nproc 2>/dev/null || echo 8)}"
PRESET_JOBS="${PRESET_JOBS:-1}"   # how many presets run concurrently (launch script)
RESERVE_CORES="${RESERVE_CORES:-1}"

if [[ -z "${NUM_SHARDS:-}" ]]; then
  if [[ "$PRESET_JOBS" -gt 1 ]]; then
    NUM_SHARDS=$(( (NPROC - RESERVE_CORES) / PRESET_JOBS ))
    [[ "$NUM_SHARDS" -lt 2 ]] && NUM_SHARDS=2
  else
    NUM_SHARDS=$((NPROC - RESERVE_CORES))
    [[ "$NUM_SHARDS" -lt 2 ]] && NUM_SHARDS=2
  fi
fi

if [[ -z "${EVAL_WORKERS:-}" ]]; then
  if [[ "$PRESET_JOBS" -gt 1 ]]; then
    EVAL_WORKERS=$(( (NPROC - RESERVE_CORES) / PRESET_JOBS ))
    [[ "$EVAL_WORKERS" -lt 2 ]] && EVAL_WORKERS=2
  else
    EVAL_WORKERS=$((NPROC - RESERVE_CORES))
    [[ "$EVAL_WORKERS" -lt 2 ]] && EVAL_WORKERS=2
  fi
fi

# Cap eval workers: each worker loads PLY + KDTree; uncapped NPROC caused 0% stalls.
MAX_EVAL_WORKERS="${MAX_EVAL_WORKERS:-32}"
if [[ "$EVAL_WORKERS" -gt "$MAX_EVAL_WORKERS" ]]; then
  EVAL_WORKERS="$MAX_EVAL_WORKERS"
fi

# Threads inside each shard/worker (OpenBLAS / OMP / MKL)
if [[ -z "${OMP_THREADS_PER_WORKER:-}" ]]; then
  OMP_THREADS_PER_WORKER=$(( NPROC / (NUM_SHARDS * PRESET_JOBS + EVAL_WORKERS) + 1 ))
  [[ "$OMP_THREADS_PER_WORKER" -lt 1 ]] && OMP_THREADS_PER_WORKER=1
  [[ "$OMP_THREADS_PER_WORKER" -gt 4 ]] && OMP_THREADS_PER_WORKER=4
fi

export NPROC NUM_SHARDS EVAL_WORKERS OMP_THREADS_PER_WORKER
export OPENBLAS_NUM_THREADS="${OPENBLAS_THREADS_PER_WORKER:-$OMP_THREADS_PER_WORKER}"
export OMP_NUM_THREADS="${OMP_THREADS_PER_WORKER}"
export MKL_NUM_THREADS="${MKL_THREADS_PER_WORKER:-$OMP_THREADS_PER_WORKER}"
export VECLIB_MAXIMUM_THREADS="${VECLIB_MAXIMUM_THREADS:-$OMP_THREADS_PER_WORKER}"
export NUMEXPR_NUM_THREADS="${NUMEXPR_NUM_THREADS:-$OMP_THREADS_PER_WORKER}"
