#!/usr/bin/env bash
# PD-LTS fine-tuned checkpoint → val565 infer (4× GPU, skip-existing resume).
#
#   PDLTS_CKPT=... bash scripts/run_pdlts_finetune_val565_infer.sh
#   RESUME=1 bash scripts/run_pdlts_finetune_val565_infer.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="${PDLTS_FT_ROOT:-$ROOT/output/pdlts_finetune_uvg}"
CG_LIST="${CG_LIST:-$ROOT/data/processed/val_cg_only_official_cgv2.txt}"
OUT_DIR="${PDLTS_OUT:-$BASE/val565/light}"
LOG_DIR="${LOG_DIR:-$BASE/logs/val565_infer}"
RESUME="${RESUME:-1}"
STAGGER_SEC="${STAGGER_SEC:-10}"
CLUSTER_SIZE="${CLUSTER_SIZE:-50000}"

if [[ -z "${PDLTS_CKPT:-}" ]]; then
  PDLTS_CKPT="$(ls -t "$BASE"/run_*/DenoiseFlow-light-UVG-finetune.ckpt 2>/dev/null | head -1 || true)"
fi
[[ -n "${PDLTS_CKPT:-}" && -f "$PDLTS_CKPT" ]] || {
  echo "Missing fine-tune ckpt. Set PDLTS_CKPT=..." >&2
  exit 1
}

mkdir -p "$LOG_DIR" "$OUT_DIR"
source /root/miniconda3/etc/profile.d/conda.sh
conda activate superpc
export OPENBLAS_NUM_THREADS=4
export OMP_NUM_THREADS=4
export MKL_NUM_THREADS=4
export PYTHONPATH="$ROOT/scripts:${PYTHONPATH:-}"
PYTHON="${CONDA_PREFIX}/bin/python"

log() { echo "[pdlts_ft_infer] $(date +%H:%M:%S) $*"; }

if [[ "$RESUME" != "1" ]]; then
  pkill -f "run_pdlts_infer.py.*${OUT_DIR}" 2>/dev/null || true
  sleep 2
fi

shard_worker_running() {
  local list="$1"
  pgrep -af "run_pdlts_infer.py" 2>/dev/null | grep -F "$list" >/dev/null 2>&1
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
      log "GPU${gpu}: nothing pending (shard ${shard_idx})"
      continue
    fi
    if [[ "$RESUME" == "1" ]] && shard_worker_running "$list"; then
      log "GPU${gpu}: worker already running — skip"
      continue
    fi
    local logfile="$LOG_DIR/gpu${gpu}.log"
    log "GPU${gpu}: ${n} pending -> $logfile ckpt=$(basename "$PDLTS_CKPT")"
    (
      export CUDA_VISIBLE_DEVICES="$gpu"
      cd "$ROOT"
      exec "$PYTHON" "$ROOT/scripts/run_pdlts_infer.py" \
        --cg-list "$list" \
        --out-dir "$OUT_DIR" \
        --model light \
        --ckpt "$PDLTS_CKPT" \
        --cluster-size "$CLUSTER_SIZE" \
        --device cuda
    ) >> "$logfile" 2>&1 &
    echo $! > "${logfile}.pid"
    sleep "$STAGGER_SEC"
  done
}

log "ckpt=$PDLTS_CKPT out=$OUT_DIR RESUME=$RESUME"
launch_sharded
log "workers launched — monitor: bash scripts/show_pdlts_finetune_val565_progress.sh"
