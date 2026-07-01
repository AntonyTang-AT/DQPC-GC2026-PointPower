#!/usr/bin/env bash
# One fusion preset: sharded refine + eval.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRESET="${PRESET:?}"
OUT_DIR="${OUT_DIR:?}"
GEOMETRY_DIR="${GEOMETRY_DIR:?}"
GEOMETRY_SECONDARY_DIR="${GEOMETRY_SECONDARY_DIR:?}"
CG_LIST="${CG_LIST:-$ROOT/data/processed/val_cg_only_official_cgv2.txt}"
PAIRS="${PAIRS:-$ROOT/data/processed/val_pairs_official_cgv2.txt}"
LOGDIR="${LOGDIR:-$(dirname "$OUT_DIR")/logs}"
NUM_SHARDS="${NUM_SHARDS:-32}"
EVAL_WORKERS="${EVAL_WORKERS:-16}"
FORCE_RERUN="${FORCE_RERUN:-0}"

mkdir -p "$OUT_DIR" "$LOGDIR"

if [[ "$FORCE_RERUN" == "1" ]]; then
  echo "[ft_fusion_one] FORCE_RERUN: clearing $OUT_DIR/*.ply and eval"
  find "$OUT_DIR" -name '*.ply' -delete 2>/dev/null || true
  rm -f "$OUT_DIR/evaluation_gc_baseline_val565.json" "$OUT_DIR/evaluation_gc_baseline_val565.csv"
  rm -f "$OUT_DIR/infer_meta.json"
fi
source /root/miniconda3/etc/profile.d/conda.sh
conda activate superpc
export PYTHONPATH="$ROOT/scripts:${PYTHONPATH:-}"

echo "[ft_fusion_one] preset=$PRESET out=$OUT_DIR"
echo "  primary=$GEOMETRY_DIR"
echo "  secondary=$GEOMETRY_SECONDARY_DIR"
[[ -n "${ENH_HISTORY_DIR:-}" ]] && echo "  enh_history=$ENH_HISTORY_DIR"

if [[ $(find "$OUT_DIR" -name '*.ply' 2>/dev/null | wc -l) -lt 565 ]]; then
  SHARD_ENV=(
    PRESET="$PRESET" OUT_DIR="$OUT_DIR" GEOMETRY_DIR="$GEOMETRY_DIR"
    GEOMETRY_SECONDARY_DIR="$GEOMETRY_SECONDARY_DIR"
    CG_LIST="$CG_LIST" LOGDIR="$LOGDIR" NUM_SHARDS="$NUM_SHARDS"
  )
  if [[ -n "${ENH_HISTORY_DIR:-}" ]]; then
    SHARD_ENV+=(ENH_HISTORY_DIR="$ENH_HISTORY_DIR")
  fi
  if [[ "$FORCE_RERUN" == "1" ]]; then
    SHARD_ENV+=(REFINE_NO_SKIP_EXISTING=1)
  fi
  env "${SHARD_ENV[@]}" bash "$ROOT/scripts/run_enh_refine_sharded.sh"
fi

ev="$OUT_DIR/evaluation_gc_baseline_val565.json"
if [[ ! -f "$ev" ]]; then
  nice -n 10 env GC2026_EVAL_PARALLEL=1 OMP_NUM_THREADS=1 \
    python "$ROOT/scripts/evaluate_gc_baseline_metrics.py" \
    --pairs-file "$PAIRS" --test-root "$OUT_DIR" --test-mode enh \
    --workers "$EVAL_WORKERS" --also-cg \
    --out-json "$ev" \
    --out-csv "$OUT_DIR/evaluation_gc_baseline_val565.csv" \
    2>&1 | tee "${LOGDIR:-$(dirname "$OUT_DIR")/logs}/eval.log"
fi
echo "[ft_fusion_one] done $PRESET"
