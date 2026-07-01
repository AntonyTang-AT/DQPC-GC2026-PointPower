#!/usr/bin/env bash
# Fine-tune val565: temporal-attention hybrid (last stage; needs ft density as ENH history).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRID="${GRID_ROOT:-$ROOT/output/ft_val565_fusion}"
PDLTS_GEOM="${PDLTS_GEOM:-$ROOT/output/pdlts_finetune_uvg/val565/light}"
PDLTS_REFINE="${PDLTS_REFINE:-$ROOT/output/pdlts_finetune_uvg/val565_refine/pdlts_light_snap1_fill0.6_density}"
SUPERPC_GEOM="${SUPERPC_GEOM:-$ROOT/output/submission_candidate}"
PRESET="temporal_attn_hybrid_pdlts_superpc_snap1_fill0.6_density"
OUT_DIR="${OUT_DIR:-$GRID/$PRESET}"
LOGDIR="${LOGDIR:-$GRID/logs/$PRESET}"
ENH_HISTORY_DIR="${ENH_HISTORY_DIR:-$PDLTS_REFINE}"

log() { echo "[ft_temporal_attn] $(date +%H:%M:%S) $*"; }

n_p=$(find "$PDLTS_GEOM" -name '*.ply' 2>/dev/null | wc -l)
n_s=$(find "$SUPERPC_GEOM" -name '*.ply' 2>/dev/null | wc -l)
n_h=$(find "$ENH_HISTORY_DIR" -name '*.ply' 2>/dev/null | wc -l)
[[ "$n_p" -ge 565 && "$n_s" -ge 565 && "$n_h" -ge 565 ]] || {
  log "blocked: pdlts=${n_p}/565 superpc=${n_s}/565 history=${n_h}/565"
  exit 1
}

log "preset=$PRESET history=$ENH_HISTORY_DIR"
PRESET="$PRESET" OUT_DIR="$OUT_DIR" GEOMETRY_DIR="$PDLTS_GEOM" \
  GEOMETRY_SECONDARY_DIR="$SUPERPC_GEOM" ENH_HISTORY_DIR="$ENH_HISTORY_DIR" \
  LOGDIR="$LOGDIR" \
  bash "$ROOT/scripts/run_ft_fusion_one.sh"
log "done -> $OUT_DIR"
