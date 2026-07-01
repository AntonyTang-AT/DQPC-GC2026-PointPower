#!/usr/bin/env bash
# Apply temporal smoothing on top of an existing refine output (val565 smoke).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${PY:-python}"
IN="${1:-$ROOT/output/enh_refine_p0_p1_p2/pdlts_light_snap1_fill0.6_density}"
OUT="${2:-$ROOT/output/enh_refine_temporal_smoke/density_temporal_w5}"
WIN="${TEMPORAL_WINDOW:-5}"
MODE="${TEMPORAL_MODE:-mean}"

CG_LIST="$ROOT/data/processed/val_pairs_official_cgv2.txt"
PAIRS="$ROOT/data/processed/val_pairs_official_cgv2.txt"

mkdir -p "$(dirname "$OUT")"
"$PY" "$ROOT/scripts/run_enh_temporal_smooth.py" \
  --in-dir "$IN" \
  --out-dir "$OUT" \
  --window "$WIN" \
  --mode "$MODE"

echo "[smoke] eval temporal output"
"$PY" "$ROOT/scripts/evaluate_gc_baseline_metrics.py" \
  --pairs-file "$PAIRS" \
  --test-root "$OUT" \
  --test-mode enh \
  --out-json "$OUT/evaluation_gc_baseline_val565.json" \
  --also-cg

echo "Done -> $OUT"
