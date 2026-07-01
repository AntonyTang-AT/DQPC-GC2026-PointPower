#!/usr/bin/env bash
# Post-process Full Pipeline (N0 v2): manifest, runtime, eval, optional pack.
set -euo pipefail

GC2026_ROOT="${GC2026_ROOT:-${GC2026_ROOT}}"
OUT="${OUT_DIR:-${GC2026_ROOT}/output/full_pipeline_n0_v2_candidate}"
RECON_ROOT="${RECON_ROOT:-${GC2026_ROOT}/output/full_pipeline_n0_v2_cg}"
GATE_JSON="${SUBMISSION_ROOT}/config/gate_decision.json"
LOG="${GC2026_ROOT}/output/post_full_pipeline.log"
N_SAMPLES="${N_SAMPLES:-20000}"
UVG_CG_VERSION="${UVG_CG_VERSION:-v2}"
EVAL_DEVICE="${EVAL_DEVICE:-cpu}"
STAGE1_TAG="${STAGE1_TAG:-N0_cwipc_official}"
PACK_TAR="${PACK_TAR:-0}"
RUN_SMOOTH="${RUN_SMOOTH:-0}"

exec > >(tee -a "$LOG") 2>&1
echo "[post_full] START $(date -Is) OUT=$OUT RECON=$RECON_ROOT"

post_progress() {
  echo "[post_full] PROGRESS step=$1 $(date +%H:%M:%S)"
}

source "${SCRIPT_DIR}/env_setup.sh"

VAL_PAIRS="${UVG_VAL_PAIRS_FILE:-${GC2026_ROOT}/data/processed/val_pairs_official_cgv2.txt}"
ALL_PAIRS="${GC2026_ROOT}/data/processed/all_pairs_cgv2.txt"
if [[ ! -f "$VAL_PAIRS" ]]; then
  echo "[post_full] WARN: official val pairs missing — run scripts/build_split_pairs.py"
  VAL_PAIRS="${GC2026_ROOT}/data/processed/val_pairs_cgv2.txt"
fi

n=$(find "$OUT" -name '*.ply' 2>/dev/null | wc -l)
echo "[post_full] ply_count=$n"

post_progress "runtime_summary"
python "${SCRIPT_DIR}/write_runtime_summary.py" \
  --out-dir "$OUT" \
  --team "GC2026 Team" || true

post_progress "manifest"
python "${SCRIPT_DIR}/make_submission.py" \
  --enhanced-dir "$OUT" \
  --team "GC2026 Team" \
  --processing-track "Full Pipeline" \
  --title "UVG-CWI-DQPC GC2026 Full Pipeline N0 v2 SuperPC" \
  --post-processing "$GATE_JSON" \
  --cg-version "$UVG_CG_VERSION" \
  --cg-source "reconstructed" \
  --stage1-tag "$STAGE1_TAG" \
  --data-split "official_val=TrumanShow,VictoryHeart,VirtualLife" \
  --pipeline-notes "RGBD bag -> cwipc-native Stage1 (${STAGE1_TAG}) -> SuperPC blend_cg enhancement"

post_progress "evaluate_uvg_official_val"
python "${SCRIPT_DIR}/evaluate_uvg.py" \
  --pairs-file "$VAL_PAIRS" \
  --enhanced-root "$OUT" \
  --n-samples "$N_SAMPLES" \
  --device "$EVAL_DEVICE" \
  --out-json "${OUT}/evaluation_official_val_n20k.json" &
PID_VAL=$!

if [[ "${SKIP_FULL_UVG:-0}" == "1" ]]; then
  echo "[post_full] SKIP_FULL_UVG=1 — skip full 2155 evaluate_uvg"
  wait "$PID_VAL" || echo "[post_full] WARN: evaluate_uvg official val partial failure"
else
  post_progress "evaluate_uvg_full"
  python "${SCRIPT_DIR}/evaluate_uvg.py" \
    --pairs-file "$ALL_PAIRS" \
    --enhanced-root "$OUT" \
    --n-samples "$N_SAMPLES" \
    --device "$EVAL_DEVICE" \
    --out-json "${OUT}/evaluation_full_n20k.json" &
  PID_FULL=$!
  wait "$PID_VAL" "$PID_FULL" || echo "[post_full] WARN: evaluate_uvg partial failure"
fi

# Back-compat symlink names used in docs
cp -f "${OUT}/evaluation_official_val_n20k.json" "${OUT}/evaluation_val_n20k.json" 2>/dev/null || true

mkdir -p "${GC2026_ROOT}/output/enhancement_eval"
python "${SCRIPT_DIR}/summarize_eval_by_sequence.py" \
  --eval-json "${OUT}/evaluation_official_val_n20k.json" \
  --out-json "${GC2026_ROOT}/output/enhancement_eval/per_sequence_full_pipeline_official_val.json" \
  || true

RECON_LIST="${RECON_ROOT}/reconstructed_cg_list.txt"
if [[ -f "$RECON_LIST" ]]; then
  post_progress "evaluate_recon_pipeline"
  python "${SCRIPT_DIR}/evaluate_recon_pipeline.py" \
    --recon-list "$RECON_LIST" \
    --enhanced-root "$OUT" \
    --n-samples "$N_SAMPLES" \
    --device "$EVAL_DEVICE" \
    --out-json "${OUT}/evaluation_recon_pipeline.json" \
    || true
fi

if [[ "${SKIP_FULL_UVG:-0}" != "1" ]]; then
  post_progress "color_temporal"
  python "${SCRIPT_DIR}/evaluate_color.py" \
    --pairs-file "$VAL_PAIRS" \
    --enhanced-root "$OUT" \
    --out-json "${OUT}/color_evaluation_official_val.json" \
    || true

  python "${SCRIPT_DIR}/evaluate_temporal.py" \
    --enhanced-root "$OUT" \
    --out-json "${OUT}/temporal_stability.json" || true
fi

PACK_SRC="$OUT"
if [[ "$RUN_SMOOTH" == "1" ]]; then
  post_progress "temporal_smooth"
  SMOOTH="${OUT}_smoothed"
  if python "${SCRIPT_DIR}/temporal_smooth.py" \
    --in-dir "$OUT" \
    --out-dir "$SMOOTH" \
    --window 5; then
    PACK_SRC="$SMOOTH"
  fi
fi

if [[ "$PACK_TAR" == "1" ]]; then
  post_progress "pack_tar"
  OUT_TAR="${GC2026_ROOT}/output/$(basename "$OUT")_submission.tar.gz"
  echo "[post_full] Creating $OUT_TAR from $PACK_SRC ..."
  tar -czf "$OUT_TAR" -C "$(dirname "$PACK_SRC")" "$(basename "$PACK_SRC")" || \
    echo "[post_full] WARN: tar pack failed"
fi

echo "[post_full] END $(date -Is)"
