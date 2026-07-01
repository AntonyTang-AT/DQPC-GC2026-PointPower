#!/usr/bin/env bash
# Post-process Enhancement Only candidate: manifest, runtime, official val eval.
set -euo pipefail

GC2026_ROOT="${GC2026_ROOT:-${GC2026_ROOT}}"
OUT="${OUT_DIR:-${GC2026_ROOT}/output/submission_candidate}"
GATE_JSON="${GC2026_ROOT}/output/val_grid/gate_decision.json"
LOG="${GC2026_ROOT}/output/post_submission_candidate.log"
N_SAMPLES="${N_SAMPLES:-20000}"
UVG_CG_VERSION="${UVG_CG_VERSION:-v2}"
EVAL_DEVICE="${EVAL_DEVICE:-cpu}"
PACK_TAR="${PACK_TAR:-0}"
RUN_SMOOTH="${RUN_SMOOTH:-0}"

exec > >(tee -a "$LOG") 2>&1
echo "[post_candidate] START $(date -Is) OUT=$OUT"

post_progress() {
  echo "[post_candidate] PROGRESS step=$1 $(date +%H:%M:%S)"
}

source "${SCRIPT_DIR}/env_setup.sh"

VAL_PAIRS="${UVG_VAL_PAIRS_FILE:-${GC2026_ROOT}/data/processed/val_pairs_official_cgv2.txt}"
ALL_PAIRS="${GC2026_ROOT}/data/processed/all_pairs_cgv2.txt"
if [[ ! -f "$VAL_PAIRS" ]]; then
  echo "[post_candidate] WARN: official val pairs missing — run scripts/build_split_pairs.py"
  VAL_PAIRS="${GC2026_ROOT}/data/processed/val_pairs_cgv2.txt"
fi

if [[ -f "$GATE_JSON" ]]; then
  python3 -c "import json; d=json.load(open('$GATE_JSON')); print('gate', d.get('gate_passed'), d.get('best_experiment'))" || true
fi

n=$(find "$OUT" -name '*.ply' 2>/dev/null | wc -l)
echo "[post_candidate] ply_count=$n"

post_progress "runtime_summary"
python "${SCRIPT_DIR}/write_runtime_summary.py" \
  --out-dir "$OUT" \
  --team "GC2026 Team" || true

post_progress "manifest"
python "${SCRIPT_DIR}/make_submission.py" \
  --enhanced-dir "$OUT" \
  --team "GC2026 Team" \
  --processing-track "Enhancement Only" \
  --title "UVG-CWI-DQPC GC2026 Enhancement Only SuperPC" \
  --post-processing "$GATE_JSON" \
  --cg-version "$UVG_CG_VERSION" \
  --cg-source "official" \
  --data-split "official_val=TrumanShow,VictoryHeart,VirtualLife" \
  --pipeline-notes "Official CGv2 -> SuperPC blend_cg enhancement"

post_progress "evaluate_uvg_official_val"
python "${SCRIPT_DIR}/evaluate_uvg.py" \
  --pairs-file "$VAL_PAIRS" \
  --enhanced-root "$OUT" \
  --n-samples "$N_SAMPLES" \
  --device "$EVAL_DEVICE" \
  --out-json "${OUT}/evaluation_official_val_n20k.json" &
PID_VAL=$!

if [[ "${SKIP_FULL_UVG:-0}" == "1" ]]; then
  echo "[post_candidate] SKIP_FULL_UVG=1 — skip full 2155 evaluate_uvg"
  wait "$PID_VAL" || echo "[post_candidate] WARN: evaluate_uvg official val partial failure"
else
  post_progress "evaluate_uvg_full"
  python "${SCRIPT_DIR}/evaluate_uvg.py" \
    --pairs-file "$ALL_PAIRS" \
    --enhanced-root "$OUT" \
    --n-samples "$N_SAMPLES" \
    --device "$EVAL_DEVICE" \
    --out-json "${OUT}/evaluation_full_n20k.json" &
  PID_FULL=$!
  wait "$PID_VAL" "$PID_FULL" || echo "[post_candidate] WARN: evaluate_uvg partial failure"
fi

cp -f "${OUT}/evaluation_official_val_n20k.json" "${OUT}/evaluation_val_n20k.json" 2>/dev/null || true

mkdir -p "${GC2026_ROOT}/output/enhancement_eval"
python "${SCRIPT_DIR}/summarize_eval_by_sequence.py" \
  --eval-json "${OUT}/evaluation_official_val_n20k.json" \
  --out-json "${GC2026_ROOT}/output/enhancement_eval/per_sequence_enh_official_val.json" \
  || true

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
    if [[ -f "${OUT}/evaluation_official_val_n20k.json" ]]; then
      python "${SCRIPT_DIR}/evaluate_uvg.py" \
        --pairs-file "$VAL_PAIRS" \
        --enhanced-root "$SMOOTH" \
        --n-samples "$N_SAMPLES" \
        --device "$EVAL_DEVICE" \
        --out-json "${SMOOTH}/evaluation_official_val_n20k.json" || true
      raw_improve=$(python3 -c "import json;print(json.load(open('${OUT}/evaluation_official_val_n20k.json'))['summary']['mean_improvement_cd_l1'])" 2>/dev/null || echo "0")
      smooth_improve=$(python3 -c "import json;print(json.load(open('${SMOOTH}/evaluation_official_val_n20k.json'))['summary']['mean_improvement_cd_l1'])" 2>/dev/null || echo "0")
      if python3 -c "import sys; r=float('$raw_improve'); s=float('$smooth_improve'); sys.exit(0 if s > r else 1)" 2>/dev/null; then
        PACK_SRC="$SMOOTH"
      fi
    fi
  fi
fi

if [[ "$PACK_TAR" == "1" ]]; then
  post_progress "pack_tar"
  bash "${SCRIPT_DIR}/pack_submission.sh" "$PACK_SRC" || true
fi

python "${SCRIPT_DIR}/generate_status_report.py" 2>/dev/null || true

echo "[post_candidate] END $(date -Is)"
