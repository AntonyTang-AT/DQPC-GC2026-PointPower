#!/usr/bin/env bash
# SuperPC val565 4-GPU infer (gate params). Used when UVG fine-tune train code is unavailable.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CG_LIST="${CG_LIST:-$ROOT/data/processed/val_cg_only_official_cgv2.txt}"
OUT_DIR="${SUPERPC_OUT:-$ROOT/output/superpc_uvg_pipeline/val565}"
LOG_DIR="${LOG_DIR:-$ROOT/output/superpc_uvg_pipeline/logs}"
RESUME="${RESUME:-1}"
STAGGER_SEC="${STAGGER_SEC:-10}"

CKPT="${SUPERPC_CKPT:-$ROOT/models/superpc_pretrained/kitti360_com.pth}"
OUTPUT_MODE="${OUTPUT_MODE:-blend_cg}"
BLEND_VOXEL_MM="${BLEND_VOXEL_MM:-3.0}"
NUM_POINTS="${NUM_POINTS:-11520}"
TARGET_NUM_POINTS="${TARGET_NUM_POINTS:-46080}"
SAMPLING_STEPS="${SAMPLING_STEPS:-25}"

mkdir -p "$LOG_DIR" "$OUT_DIR"
source /root/miniconda3/etc/profile.d/conda.sh
conda activate superpc
export PYTHONPATH="$ROOT/scripts:${PYTHONPATH:-}"
PYTHON="${CONDA_PREFIX}/bin/python"

log() { echo "[superpc_val565] $(date +%H:%M:%S) $*"; }

[[ -f "$CKPT" ]] || { echo "Missing ckpt: $CKPT" >&2; exit 1; }

if [[ "$RESUME" != "1" ]]; then
  pkill -f "run_superpc_infer.py.*${OUT_DIR}" 2>/dev/null || true
  sleep 2
fi

shard_worker_running() {
  local list="$1"
  pgrep -af "run_superpc_infer.py" 2>/dev/null | grep -F "$list" >/dev/null 2>&1
}

launch_sharded() {
  local -a gpus=(0 1 2 3)
  local num_shards=${#gpus[@]}
  local shard_dir="$OUT_DIR/.shards_${num_shards}gpu"
  mkdir -p "$shard_dir"

  "$PYTHON" "$ROOT/scripts/split_pending_cg_list.py" \
    --cg-list "$CG_LIST" \
    --out-dir "$OUT_DIR" \
    --shard-dir "$shard_dir" \
    --num-shards "$num_shards"

  for shard_idx in "${!gpus[@]}"; do
    local gpu="${gpus[$shard_idx]}"
    local list
    list="$(cd "$shard_dir" && pwd)/pending_${shard_idx}.txt"
    local n=0
    [[ -f "$list" ]] && n=$(wc -l < "$list" | tr -d ' ')
    if [[ "$n" -eq 0 ]]; then
      log "GPU${gpu}: nothing pending"
      continue
    fi
    if [[ "$RESUME" == "1" ]] && shard_worker_running "$list"; then
      log "GPU${gpu}: already running — skip"
      continue
    fi
    local logfile="$LOG_DIR/gpu${gpu}.log"
    log "GPU${gpu}: ${n} pending mode=${OUTPUT_MODE} vx=${BLEND_VOXEL_MM} -> $logfile"
    (
      export CUDA_VISIBLE_DEVICES="$gpu"
      cd "$ROOT"
      exec "$PYTHON" "$ROOT/scripts/run_superpc_infer.py" \
        --cg-list "$list" \
        --ckpt-path "$CKPT" \
        --out-dir "$OUT_DIR" \
        --num-points "$NUM_POINTS" \
        --target-num-points "$TARGET_NUM_POINTS" \
        --sampling-steps "$SAMPLING_STEPS" \
        --output-mode "$OUTPUT_MODE" \
        --blend-voxel-mm "$BLEND_VOXEL_MM" \
        --device cuda:0 \
        --skip-existing
    ) >> "$logfile" 2>&1 &
    echo $! > "${logfile}.pid"
    sleep "$STAGGER_SEC"
  done
}

log "out=$OUT_DIR ckpt=$(basename "$CKPT") mode=$OUTPUT_MODE"
launch_sharded
log "workers launched"
