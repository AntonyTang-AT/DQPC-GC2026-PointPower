#!/usr/bin/env bash
# Unified Enh pipeline entry (write-only orchestration; run when GPU/cache ready).
#
# Stages:
#   1. refine infer  (--preset or gate json; needs PD-LTS cache or GPU)
#   2. temporal smooth (CPU)
#   3. eval val565 (CPU)
#
# CPU-only (no GPU): skip stage 1, point IN at existing refine output:
#   STAGE=post IN=output/enh_refine_p0_p1_p2/pdlts_light_snap1_fill0.6_density \
#     OUT=output/enh_refine_temporal/density_w5 bash scripts/run_enh_unified.sh
#
# Hybrid PD-LTS + SuperPC (CPU if both caches exist):
#   PRESET=hybrid_pdlts_superpc_snap1_fill0.6_density bash scripts/run_enh_unified.sh
#
# Full-pipeline migrated preset (pre-SOR + adaptive + density fill):
#   PRESET=fp_migrated_pre25_density bash scripts/run_enh_unified.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${PY:-python3}"
STAGE="${STAGE:-all}"
PRESET="${PRESET:-pdlts_light_snap1_fill0.6_density}"
CG_LIST="${CG_LIST:-$ROOT/data/processed/val_pairs_official_cgv2.txt}"
PAIRS="${PAIRS_FILE:-$CG_LIST}"
OUT="${OUT:-$ROOT/output/enh_refine_unified/$PRESET}"
IN="${IN:-$OUT}"
GATE="${GATE:-$ROOT/output/enh_refine_p0_p1_p2/gate_decision.json}"
TEMPORAL="${TEMPORAL:-1}"
TEMPORAL_WIN="${TEMPORAL_WINDOW:-5}"
TEMPORAL_OUT="${TEMPORAL_OUT:-${OUT}_temporal_w${TEMPORAL_WIN}}"

run_infer() {
  local out_dir="$1"
  mkdir -p "$out_dir"
  if [[ -n "${REFINE_CONFIG:-}" ]]; then
    "$PY" "$ROOT/scripts/run_enh_refine_infer.py" \
      --cg-list "$CG_LIST" \
      --out-dir "$out_dir" \
      --refine-config "$REFINE_CONFIG" \
      --use-geometry-cache --require-geometry-cache
  elif [[ "$PRESET" == hybrid_* ]]; then
    "$PY" "$ROOT/scripts/run_enh_refine_infer.py" \
      --cg-list "$CG_LIST" \
      --out-dir "$out_dir" \
      --preset "$PRESET" \
      --use-geometry-cache --require-geometry-cache
  else
    "$PY" "$ROOT/scripts/run_enh_refine_infer.py" \
      --cg-list "$CG_LIST" \
      --out-dir "$out_dir" \
      --preset "$PRESET" \
      --use-geometry-cache --require-geometry-cache
  fi
}

run_temporal() {
  local in_dir="$1" out_dir="$2"
  EVAL=0 "$ROOT/scripts/run_enh_cpu_post.sh" "$in_dir" "$out_dir"
}

run_eval() {
  local test_root="$1"
  "$PY" "$ROOT/scripts/evaluate_gc_baseline_metrics.py" \
    --pairs-file "$PAIRS" \
    --test-root "$test_root" \
    --test-mode enh \
    --out-json "$test_root/evaluation_gc_baseline_val565.json" \
    --also-cg
}

case "$STAGE" in
  infer)
    run_infer "$OUT"
    ;;
  temporal)
    run_temporal "$IN" "${TEMPORAL_OUT}"
    ;;
  eval)
    run_eval "${EVAL_ROOT:-$TEMPORAL_OUT}"
    ;;
  post)
    run_temporal "$IN" "$TEMPORAL_OUT"
    run_eval "$TEMPORAL_OUT"
    ;;
  apply)
    "$PY" "$ROOT/scripts/apply_enh_refine_decision.py" \
      --gate-json "$GATE" \
      --cg-list "$CG_LIST" \
      --out-dir "$OUT" \
      --geometry-dir "${GEOMETRY_DIR:-}" \
      ${TEMPORAL:+--temporal-smooth} \
      --temporal-window "$TEMPORAL_WIN"
    ;;
  all)
    run_infer "$OUT"
    if [[ "$TEMPORAL" == "1" ]]; then
      run_temporal "$OUT" "$TEMPORAL_OUT"
      run_eval "$TEMPORAL_OUT"
    else
      run_eval "$OUT"
    fi
    ;;
  *)
    echo "Unknown STAGE=$STAGE (infer|temporal|eval|post|apply|all)"
    exit 1
    ;;
esac

echo "[unified] STAGE=$STAGE complete"
