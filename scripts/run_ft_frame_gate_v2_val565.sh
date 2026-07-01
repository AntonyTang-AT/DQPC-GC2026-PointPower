#!/usr/bin/env bash
# val565: architecture-v2 fusion (ft density base + frame gate SuperPC).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRESET="${PRESET:-holefill_adaptive_frame_gate_v2}"
OUT_DIR="${OUT_DIR:-$ROOT/output/ft_val565_fusion/holefill_adaptive_frame_gate_v2}"
GEOMETRY_DIR="${GEOMETRY_DIR:-$ROOT/output/pdlts_finetune_uvg/val565/light}"
GEOMETRY_SECONDARY_DIR="${GEOMETRY_SECONDARY_DIR:-$ROOT/output/submission_candidate}"
LOGDIR="${LOGDIR:-$ROOT/output/ft_val565_fusion/logs_frame_gate_v2}"
NUM_SHARDS="${NUM_SHARDS:-}"
EVAL_WORKERS="${EVAL_WORKERS:-}"
FORCE_RERUN="${FORCE_RERUN:-1}"

source "$ROOT/scripts/cpu_parallel_defaults.sh"

mkdir -p "$LOGDIR"
exec > >(tee -a "$LOGDIR/orchestrator.log") 2>&1
echo "[frame_gate_v2] start $(date -Is) preset=$PRESET shards=$NUM_SHARDS eval_workers=$EVAL_WORKERS"

env PRESET="$PRESET" OUT_DIR="$OUT_DIR" \
  GEOMETRY_DIR="$GEOMETRY_DIR" GEOMETRY_SECONDARY_DIR="$GEOMETRY_SECONDARY_DIR" \
  LOGDIR="$LOGDIR" NUM_SHARDS="$NUM_SHARDS" EVAL_WORKERS="$EVAL_WORKERS" \
  FORCE_RERUN="$FORCE_RERUN" \
  bash "$ROOT/scripts/run_ft_fusion_one.sh"

echo "[frame_gate_v2] done $(date -Is)"
