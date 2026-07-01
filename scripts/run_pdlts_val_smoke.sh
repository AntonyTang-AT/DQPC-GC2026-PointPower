#!/usr/bin/env bash
# Smoke: 5 val565 frames -> PD-LTS -> official chamfer eval
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAIRS="$ROOT/data/processed/val_pairs_official_cgv2.txt"
CG_LIST="/tmp/pdlts_smoke_cg.txt"
OUT="$ROOT/output/pdlts_smoke_val565"
N="${1:-5}"

head -n "$N" "$PAIRS" | cut -f1 > "$CG_LIST"

source /root/miniconda3/etc/profile.d/conda.sh
conda activate superpc

python "$ROOT/scripts/run_pdlts_infer.py" \
  --cg-list "$CG_LIST" \
  --out-dir "$OUT" \
  --model light \
  --cluster-size 50000 \
  --verbose

python "$ROOT/scripts/evaluate_gc_baseline_metrics.py" \
  --pairs-file "$PAIRS" \
  --test-root "$OUT" \
  --max-frames "$N" \
  --out-json "$OUT/evaluation_gc_baseline_smoke.json" \
  --out-csv "$OUT/evaluation_gc_baseline_smoke.csv"

echo "[smoke] results: $OUT/evaluation_gc_baseline_smoke.json"
