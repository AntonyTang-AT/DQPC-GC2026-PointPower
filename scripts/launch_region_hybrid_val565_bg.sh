#!/usr/bin/env bash
# Launch val565 region hybrid jobs in background — **parallel presets + full CPU**.
#
#   bash scripts/launch_region_hybrid_val565_bg.sh
#   PRESET_JOBS=2 SEQUENTIAL_PRESETS=0 bash scripts/launch_region_hybrid_val565_bg.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRID="${GRID_ROOT:-$ROOT/output/enh_refine_val565_selection}"
LOGDIR="$GRID/logs/region_hybrid"
SEQUENTIAL_PRESETS="${SEQUENTIAL_PRESETS:-0}"
PRESET_JOBS="${PRESET_JOBS:-2}"

mkdir -p "$LOGDIR"

PRESETS=(
  region_hybrid_pdlts_superpc_snap1_fill0.6_density
  temporal_region_hybrid_pdlts_superpc_snap1_fill0.6_density
)

# shellcheck source=cpu_parallel_defaults.sh
source "$ROOT/scripts/cpu_parallel_defaults.sh"
echo "[launch] NPROC=$NPROC PRESET_JOBS=$PRESET_JOBS NUM_SHARDS=$NUM_SHARDS EVAL_WORKERS=$EVAL_WORKERS OMP=$OMP_NUM_THREADS"

launch_one() {
  local preset="$1"
  local log="$LOGDIR/${preset}_val565.log"
  local out="$GRID/$preset"
  local done
  done=$(find "$out" -name '*.ply' 2>/dev/null | wc -l)

  if pgrep -f "run_region_hybrid_val565.sh.*${preset}" >/dev/null 2>&1; then
    echo "[launch] skip $preset — already running"
    return 0
  fi
  if [[ "$done" -ge 565 ]] && [[ -f "$out/evaluation_gc_baseline_val565.json" ]]; then
    echo "[launch] skip $preset — complete ($done/565 + eval)"
    return 0
  fi

  local skip_infer=0
  if [[ "$done" -ge 565 ]]; then
    skip_infer=1
    echo "[launch] $preset infer done ($done/565) — eval-only parallel"
  else
    echo "[launch] $preset infer+eval ($done/565) shards=$NUM_SHARDS"
  fi

  nohup env PRESET="$preset" OUT_DIR="$out" PRESET_JOBS="$PRESET_JOBS" \
    NUM_SHARDS="$NUM_SHARDS" EVAL_WORKERS="$EVAL_WORKERS" \
    OMP_THREADS_PER_WORKER="$OMP_THREADS_PER_WORKER" SKIP_INFER="$skip_infer" \
    bash "$ROOT/scripts/run_region_hybrid_val565.sh" val565 \
    > "$log" 2>&1 &
  echo "  pid=$! log=$log"
}

echo "[launch] val565 (TrumanShow + VictoryHeart + VirtualLife, 565 frames)"
PIDS=()
for preset in "${PRESETS[@]}"; do
  launch_one "$preset"
  if [[ "$SEQUENTIAL_PRESETS" == "1" ]]; then
    wait
  fi
done

if [[ "$SEQUENTIAL_PRESETS" != "1" ]]; then
  wait || true
fi

bash "$ROOT/scripts/show_region_hybrid_progress.sh"
