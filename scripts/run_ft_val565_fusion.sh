#!/usr/bin/env bash
# Fusion val565: fine-tuned PD-LTS primary + submission_candidate SuperPC secondary.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRID="${GRID_ROOT:-$ROOT/output/ft_val565_fusion}"
PDLTS_GEOM="${PDLTS_GEOM:-$ROOT/output/pdlts_finetune_uvg/val565/light}"
SUPERPC_GEOM="${SUPERPC_GEOM:-$ROOT/output/submission_candidate}"
LOGDIR="${LOGDIR:-$GRID/logs}"
mkdir -p "$LOGDIR"

log() { echo "[ft_fusion] $(date +%H:%M:%S) $*"; }

n_p=$(find "$PDLTS_GEOM" -name '*.ply' 2>/dev/null | wc -l)
n_s=$(find "$SUPERPC_GEOM" -name '*.ply' 2>/dev/null | wc -l)
[[ "$n_p" -ge 565 && "$n_s" -ge 565 ]] || {
  log "blocked: pdlts=${n_p}/565 superpc=${n_s}/565"
  exit 1
}

for preset in \
  region_hybrid_pdlts_superpc_snap1_fill0.6_density \
  temporal_region_hybrid_pdlts_superpc_snap1_fill0.6_density
do
  GEOMETRY_DIR="$PDLTS_GEOM" GEOMETRY_SECONDARY_DIR="$SUPERPC_GEOM" \
    PRESET="$preset" OUT_DIR="$GRID/$preset" LOGDIR="$LOGDIR/$preset" \
    bash "$ROOT/scripts/run_ft_fusion_one.sh"
done
log "all fusion presets done -> $GRID"
