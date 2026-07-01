#!/usr/bin/env bash
# Hybrid PD-LTS + SuperPC refine smoke on val565 (CPU post-process, uses caches).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${PY:-python}"
OUT="${1:-$ROOT/output/enh_refine_hybrid_smoke/hybrid_pdlts_superpc_snap1_fill0.6_density}"
PRESET="${PRESET:-hybrid_pdlts_superpc_snap1_fill0.6_density}"
CG_LIST="$ROOT/data/processed/val_pairs_official_cgv2.txt"
PAIRS="$ROOT/data/processed/val_pairs_official_cgv2.txt"

mkdir -p "$OUT"
"$PY" "$ROOT/scripts/run_enh_refine_infer.py" \
  --cg-list "$CG_LIST" \
  --out-dir "$OUT" \
  --preset "$PRESET" \
  --use-geometry-cache \
  --require-geometry-cache \
  --geometry-fallback filter_cg

echo "[hybrid smoke] eval"
"$PY" "$ROOT/scripts/evaluate_gc_baseline_metrics.py" \
  --pairs-file "$PAIRS" \
  --test-root "$OUT" \
  --test-mode enh \
  --out-json "$OUT/evaluation_gc_baseline_val565.json" \
  --also-cg

echo "Done -> $OUT"
