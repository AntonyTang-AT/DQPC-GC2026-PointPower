#!/usr/bin/env bash
# UVG train-split PD-LTS fine-tune (1590 frames; val565 held out).
#
#   bash src/setup_pdlts_train.sh          # once
#   bash src/run_pdlts_finetune_uvg.sh smoke
#   GPUS=4 bash src/run_pdlts_finetune_uvg.sh train
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
MODE="${1:-smoke}"
GPUS="${GPUS:-4}"
OUT="${OUT_DIR:-${GC2026_ROOT}/output/pdlts_finetune_uvg}"
PAIRS="${PAIRS_FILE:-${GC2026_ROOT}/data/processed/train_pairs_official_cgv2.txt}"
LOG="$OUT/logs"
mkdir -p "$LOG"

# User should have already activated conda env per SETUP.md
# source /root/miniconda3/etc/profile.d/conda.sh  # not portable on organizer's system

smoke() {
  echo "[finetune] smoke: 16 train frames, 8 batches, 1 epoch, 1 GPU"
  python "${SCRIPT_DIR}/run_pdlts_finetune_uvg.py" \
    --pairs-file "$PAIRS" \
    --out-dir "$OUT/smoke" \
    --max-train-frames 16 \
    --patches-per-epoch 64 \
    --batch-size 2 \
    --max-epochs 1 \
    --gpus 1 \
    --limit-train-batches 8 \
    --num-workers 2 \
    2>&1 | tee "$LOG/smoke.log"
}

train() {
  # Fast profile (optional): MAX_EPOCHS=8 PATCHES_PER_EPOCH=4000 BATCH_SIZE=8
  # Early stop (optional): STOP_LOSS=1.8 STOP_PATIENCE=2
  MAX_EPOCHS="${MAX_EPOCHS:-20}"
  PATCHES_PER_EPOCH="${PATCHES_PER_EPOCH:-8000}"
  BATCH_SIZE="${BATCH_SIZE:-4}"
  LR="${LEARNING_RATE:-5e-4}"
  STOP_LOSS="${STOP_LOSS:-0}"
  STOP_PATIENCE="${STOP_PATIENCE:-0}"
  echo "[finetune] full train split GPUS=$GPUS epochs=$MAX_EPOCHS patches=$PATCHES_PER_EPOCH batch=$BATCH_SIZE stop_loss=$STOP_LOSS -> $OUT"
  extra_args=()
  [[ "$STOP_LOSS" != "0" ]] && extra_args+=(--early-stop-loss "$STOP_LOSS")
  [[ "$STOP_PATIENCE" != "0" ]] && extra_args+=(--early-stop-patience "$STOP_PATIENCE")
  python "${SCRIPT_DIR}/run_pdlts_finetune_uvg.py" \
    --pairs-file "$PAIRS" \
    --out-dir "$OUT/run_$(date +%Y%m%d_%H%M%S)" \
    --patches-per-epoch "$PATCHES_PER_EPOCH" \
    --batch-size "$BATCH_SIZE" \
    --max-epochs "$MAX_EPOCHS" \
    --learning-rate "$LR" \
    --gpus "$GPUS" \
    --num-workers 8 \
    "${extra_args[@]}" \
    2>&1 | tee "$LOG/train_${GPUS}gpu.log"
}

case "$MODE" in
  smoke) smoke ;;
  train) train ;;
  *)
    echo "Usage: $0 {smoke|train}" >&2
    exit 1
    ;;
esac
