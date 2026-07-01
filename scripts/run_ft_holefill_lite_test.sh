#!/usr/bin/env bash
# Background val565 test: lite holefill preset (lower SuperPC weight).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRESET="${PRESET:-holefill_lite_fill0.25_max10pct_adaptive_post25}"
OUT_DIR="${OUT_DIR:-$ROOT/output/ft_val565_fusion/holefill_lite_fill0.25_max10pct_adaptive_post25}"
GEOMETRY_DIR="${GEOMETRY_DIR:-$ROOT/output/pdlts_finetune_uvg/val565/light}"
GEOMETRY_SECONDARY_DIR="${GEOMETRY_SECONDARY_DIR:-$ROOT/output/submission_candidate}"
LOGDIR="${LOGDIR:-$ROOT/output/ft_val565_fusion/logs_holefill_lite}"
NUM_SHARDS="${NUM_SHARDS:-32}"
EVAL_WORKERS="${EVAL_WORKERS:-16}"
FORCE_RERUN="${FORCE_RERUN:-0}"

mkdir -p "$LOGDIR"
exec > >(tee -a "$LOGDIR/orchestrator.log") 2>&1
echo "[holefill_lite] start $(date -Iseconds) preset=$PRESET"

env PRESET="$PRESET" OUT_DIR="$OUT_DIR" \
  GEOMETRY_DIR="$GEOMETRY_DIR" GEOMETRY_SECONDARY_DIR="$GEOMETRY_SECONDARY_DIR" \
  LOGDIR="$LOGDIR" NUM_SHARDS="$NUM_SHARDS" EVAL_WORKERS="$EVAL_WORKERS" \
  FORCE_RERUN="$FORCE_RERUN" \
  bash "$ROOT/scripts/run_ft_fusion_one.sh"

echo "[holefill_lite] done $(date -Iseconds)"
