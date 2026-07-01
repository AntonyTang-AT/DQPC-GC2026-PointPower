#!/usr/bin/env bash
# CPU-only post-process: temporal smooth (+ optional eval). No GPU required.
# Use after refine infer output already exists (e.g. density val565 dir).
#
# Example:
#   bash scripts/run_enh_cpu_post.sh \
#     output/enh_refine_p0_p1_p2/pdlts_light_snap1_fill0.6_density \
#     output/enh_refine_temporal/density_w5
#
# With eval:
#   EVAL=1 bash scripts/run_enh_cpu_post.sh IN OUT
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${PY:-python3}"
IN="${1:?usage: run_enh_cpu_post.sh IN_DIR OUT_DIR}"
OUT="${2:?usage: run_enh_cpu_post.sh IN_DIR OUT_DIR}"
WIN="${TEMPORAL_WINDOW:-5}"
MODE="${TEMPORAL_MODE:-mean}"
SEQ="${TEMPORAL_SEQUENCES:-}"
EVAL="${EVAL:-0}"
PAIRS="${PAIRS_FILE:-$ROOT/data/processed/val_pairs_official_cgv2.txt}"
CG_ROOT="${CG_ROOT:-$ROOT/data/raw/UVG-CWI-DQPC}"

mkdir -p "$OUT"
ARGS=(--in-dir "$IN" --out-dir "$OUT" --window "$WIN" --mode "$MODE" --cg-root "$CG_ROOT")
if [[ -n "$SEQ" ]]; then
  # shellcheck disable=SC2206
  ARGS+=(--sequences $SEQ)
fi
"$PY" "$ROOT/scripts/run_enh_temporal_smooth.py" "${ARGS[@]}"

if [[ "$EVAL" == "1" ]]; then
  WORKERS="${EVAL_WORKERS:-16}"
  "$PY" "$ROOT/scripts/evaluate_gc_baseline_metrics.py" \
    --pairs-file "$PAIRS" \
    --test-root "$OUT" \
    --test-mode enh \
    --workers "$WORKERS" \
    --out-json "$OUT/evaluation_gc_baseline_val565.json" \
    --also-cg
fi

echo "[cpu_post] done -> $OUT"
