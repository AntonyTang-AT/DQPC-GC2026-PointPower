#!/usr/bin/env bash
# Adaptive snap study: val565 sweep + train (non-val 9 seq) sample eval.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STUDY="${STUDY:-$ROOT/output/adaptive_snap_study}"
PER_SEQ="${PER_SEQ:-25}"
WORKERS="${WORKERS:-16}"
STAGE="${STAGE:-all}"
QUICK="${QUICK:-1}"

source /root/miniconda3/etc/profile.d/conda.sh
conda activate superpc
export PYTHONPATH="$ROOT/scripts:${PYTHONPATH:-}"
PY="${CONDA_PREFIX}/bin/python"
mkdir -p "$STUDY"

VAL_PAIRS="$ROOT/data/processed/val_pairs_official_cgv2.txt"
if [[ "$QUICK" == "1" ]]; then
  VAL_PAIRS="$STUDY/val_sample_pairs.txt"
  if [[ ! -f "$VAL_PAIRS" ]]; then
    "$PY" "$ROOT/scripts/sample_pairs_per_sequence.py" \
      --pairs-file "$ROOT/data/processed/val_pairs_official_cgv2.txt" \
      --out-file "$VAL_PAIRS" --per-seq 30
  fi
fi
TRAIN_PAIRS="$ROOT/data/processed/train_pairs_official_cgv2.txt"
VAL_CG="$STUDY/val_cg_list.txt"
TRAIN_SAMPLE_PAIRS="$STUDY/train_sample_pairs.txt"
TRAIN_SAMPLE_CG="$STUDY/train_sample_cg_list.txt"
VAL_GEOM="$ROOT/output/pdlts_val565/light"
TRAIN_GEOM="$STUDY/pdlts_train_sample/light"

cut -f1 "$VAL_PAIRS" > "$VAL_CG"

run_val_benchmark() {
  echo "[study] val565 adaptive snap benchmark"
  BASE_EVAL="$ROOT/output/enh_refine_p0_p1_p2/pdlts_light_snap1_fill0.6_density/evaluation_gc_baseline_val565.json"
  "$PY" "$ROOT/scripts/benchmark_adaptive_snap.py" \
    --cg-list "$VAL_CG" \
    --pairs-file "$VAL_PAIRS" \
    --geometry-dir "$VAL_GEOM" \
    --out-root "$STUDY/val565" \
    --workers "$WORKERS" \
    --skip-baseline-infer \
    --baseline-eval-json "$BASE_EVAL"
}

prepare_train_sample() {
  echo "[study] train sample pairs per_seq=$PER_SEQ"
  "$PY" "$ROOT/scripts/sample_pairs_per_sequence.py" \
    --pairs-file "$TRAIN_PAIRS" \
    --out-file "$TRAIN_SAMPLE_PAIRS" \
    --per-seq "$PER_SEQ"
  cut -f1 "$TRAIN_SAMPLE_PAIRS" > "$TRAIN_SAMPLE_CG"
  "$PY" "$ROOT/scripts/analyze_cg_inlier_by_sequence.py" \
    --pairs-file "$TRAIN_SAMPLE_PAIRS" \
    --out-json "$STUDY/train_sample_inlier.json"
}

run_train_pdlts() {
  echo "[study] PD-LTS on train sample -> $TRAIN_GEOM"
  export CG_LIST="$TRAIN_SAMPLE_CG" GEOMETRY_DIR="$TRAIN_GEOM"
  export GC2026_ROOT="$ROOT" SUBMISSION_SKIP_CONDA=1
  bash "$ROOT/submissions/GC2026_Team_EnhancementOnly/src/run_dual_gpu_pdlts.sh"
}

run_train_benchmark() {
  echo "[study] train sample benchmark"
  DENSITY_OUT="$STUDY/train_sample/pdlts_light_snap1_fill0.6_density"
  mkdir -p "$DENSITY_OUT"
  BASE_EVAL="$DENSITY_OUT/evaluation_gc_baseline.json"
  if [[ ! -f "$BASE_EVAL" ]]; then
    "$PY" "$ROOT/scripts/run_enh_refine_infer.py" \
      --cg-list "$TRAIN_SAMPLE_CG" \
      --out-dir "$DENSITY_OUT" \
      --preset pdlts_light_snap1_fill0.6_density \
      --geometry-dir "$TRAIN_GEOM" \
      --use-geometry-cache --require-geometry-cache
    "$PY" "$ROOT/scripts/evaluate_gc_baseline_metrics.py" \
      --pairs-file "$TRAIN_SAMPLE_PAIRS" \
      --test-root "$DENSITY_OUT" --test-mode enh --workers "$WORKERS" \
      --also-cg --out-json "$BASE_EVAL"
  fi
  "$PY" "$ROOT/scripts/benchmark_adaptive_snap.py" \
    --cg-list "$TRAIN_SAMPLE_CG" \
    --pairs-file "$TRAIN_SAMPLE_PAIRS" \
    --geometry-dir "$TRAIN_GEOM" \
    --out-root "$STUDY/train_sample" \
    --workers "$WORKERS" \
    --skip-baseline-infer \
    --baseline-eval-json "$BASE_EVAL"
}

case "$STAGE" in
  val) run_val_benchmark ;;
  train_prep) prepare_train_sample ;;
  train_pdlts) prepare_train_sample; run_train_pdlts ;;
  train_eval) run_train_benchmark ;;
  all)
    run_val_benchmark
    prepare_train_sample
    run_train_pdlts
    run_train_benchmark
    ;;
  *)
    echo "STAGE=val|train_prep|train_pdlts|train_eval|all"
    exit 1
    ;;
esac

echo "[study] DONE $STUDY"
