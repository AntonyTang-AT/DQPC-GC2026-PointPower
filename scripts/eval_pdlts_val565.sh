#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAIRS="$ROOT/data/processed/val_pairs_official_cgv2.txt"
source /root/miniconda3/etc/profile.d/conda.sh
conda activate superpc

for tag in light heavy; do
  OUT="$ROOT/output/pdlts_val565/$tag"
  python "$ROOT/scripts/evaluate_gc_baseline_metrics.py" \
    --pairs-file "$PAIRS" \
    --test-root "$OUT" \
    --out-json "$OUT/evaluation_gc_baseline_val565.json" \
    --out-csv "$OUT/evaluation_gc_baseline_val565.csv"
  echo "[$tag] $(python - <<PY
import json
d=json.load(open('$OUT/evaluation_gc_baseline_val565.json'))
print('chamfer=', d['means']['chamfer_distance'])
PY
)"
done
