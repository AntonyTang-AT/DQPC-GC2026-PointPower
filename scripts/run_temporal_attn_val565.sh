#!/usr/bin/env bash
# Two-pass temporal-attention hybrid on val565:
#   Pass 1: density refine (history) — reuse existing output if present
#   Pass 2: temporal_attn hybrid with ENH_HISTORY_DIR + SuperPC secondary
#
# Usage:
#   bash scripts/run_temporal_attn_val565.sh
#   ENH_HISTORY_DIR=output/pdlts_finetune_uvg/val565_refine/pdlts_light_snap1_fill0.6_density bash ...
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRID="${GRID_ROOT:-$ROOT/output/enh_refine_val565_selection}"
HISTORY="${ENH_HISTORY_DIR:-$ROOT/output/enh_refine_p0_p1_p2/pdlts_light_snap1_fill0.6_density}"
PDLTS_GEOM="${PDLTS_GEOM:-$ROOT/output/pdlts_val565/light}"
SUPERPC="${SUPERPC_GEOM:-$ROOT/output/submission_candidate}"
PRESET="temporal_attn_hybrid_pdlts_superpc_snap1_fill0.6_density"
OUT="$GRID/$PRESET"
LOGDIR="${LOGDIR:-$GRID/logs/$PRESET}"
CG_LIST="${CG_LIST:-$ROOT/data/processed/val_cg_only_official_cgv2.txt}"

n_hist=$(find "$HISTORY" -name '*.ply' 2>/dev/null | wc -l)
if [[ "$n_hist" -lt 565 ]]; then
  echo "[temporal_attn] history incomplete ${n_hist}/565 at $HISTORY" >&2
  echo "  Run density refine first or set ENH_HISTORY_DIR to a full val565 refine cache." >&2
  exit 1
fi

echo "[temporal_attn] history=$HISTORY primary=$PDLTS_GEOM secondary=$SUPERPC"
PRESET="$PRESET" OUT_DIR="$OUT" GEOMETRY_DIR="$PDLTS_GEOM" \
  GEOMETRY_SECONDARY_DIR="$SUPERPC" ENH_HISTORY_DIR="$HISTORY" \
  CG_LIST="$CG_LIST" LOGDIR="$LOGDIR" \
  bash "$ROOT/scripts/run_enh_refine_sharded.sh"

source /root/miniconda3/etc/profile.d/conda.sh
conda activate superpc
ev="$OUT/evaluation_gc_baseline_val565.json"
if [[ ! -f "$ev" ]]; then
  nice -n 10 env GC2026_EVAL_PARALLEL=1 OMP_NUM_THREADS=1 \
    python "$ROOT/scripts/evaluate_gc_baseline_metrics.py" \
    --pairs-file "$ROOT/data/processed/val_pairs_official_cgv2.txt" \
    --test-root "$OUT" --test-mode enh --workers 16 --also-cg \
    --out-json "$ev" --out-csv "$OUT/evaluation_gc_baseline_val565.csv"
fi
echo "[temporal_attn] done -> $OUT"
