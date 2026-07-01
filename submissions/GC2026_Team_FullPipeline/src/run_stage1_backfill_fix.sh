#!/usr/bin/env bash
# P1: official CG fallback for bad Stage1 backfill + re-infer + re-eval (val565).
set -euo pipefail

GC2026_ROOT="${GC2026_ROOT:-${GC2026_ROOT}}"
SCRIPT_DIR="${SCRIPT_DIR}"
PY="${PY:-python3.12}"
RECON_ROOT="${RECON_ROOT:-${GC2026_ROOT}/output/full_pipeline_n0_v2_cg}"
ENH_ROOT="${ENH_ROOT:-${GC2026_ROOT}/output/full_pipeline_n0_v2_candidate}"
VAL_PAIRS="${UVG_VAL_PAIRS_FILE:-${GC2026_ROOT}/data/processed/val_pairs_official_cgv2.txt}"
LOG="${GC2026_ROOT}/output/stage1_backfill_fix.log"
FIX_ALL="${FIX_ALL:-1}"
RUN_SUPERPC="${RUN_SUPERPC:-1}"
RUN_EVAL="${RUN_EVAL:-1}"
N_SAMPLES="${N_SAMPLES:-5000}"
EVAL_DEVICE="${EVAL_DEVICE:-cpu}"

exec > >(tee -a "$LOG") 2>&1
echo "[backfill_fix] START $(date -Is)"

source "${SCRIPT_DIR}/env_setup.sh"

VAL_RECON_LIST="${GC2026_ROOT}/output/stage1_official_cg_fallback_recon_list.txt"
ALL88_LIST="${GC2026_ROOT}/output/stage1_official_cg_fallback_all88_recon_list.txt"

echo "[backfill_fix] step1 val backfill official CG fallback..."
"$PY" "${SCRIPT_DIR}/apply_official_cg_fallback.py" \
  --recon-root "$RECON_ROOT" \
  --val-only \
  --all-backfill-list \
  --out-json "${GC2026_ROOT}/output/stage1_official_cg_fallback_val16.json"

if [[ "$FIX_ALL" == "1" ]]; then
  echo "[backfill_fix] step1b all 88 backfill Stage1 official CG fallback..."
  "$PY" "${SCRIPT_DIR}/apply_official_cg_fallback.py" \
    --recon-root "$RECON_ROOT" \
    --all-backfill-list \
    --out-json "${GC2026_ROOT}/output/stage1_official_cg_fallback_all88.json"
fi

if [[ "$RUN_SUPERPC" == "1" && -s "$VAL_RECON_LIST" ]]; then
  if "$PY" -c "import torch; raise SystemExit(0 if torch.cuda.is_available() else 1)" 2>/dev/null; then
    echo "[backfill_fix] step2 SuperPC re-infer val16 (GPU)..."
    while IFS= read -r recon; do
      [[ -z "$recon" ]] && continue
      base=$(basename "$recon")
      seq=$(basename "$(dirname "$recon")")
      enh="${ENH_ROOT}/${seq}/${base/_CG_/_ENH_}"
      if [[ -f "$enh" ]]; then
        mkdir -p "${ENH_ROOT}/_bad_enh_backup/${seq}"
        mv "$enh" "${ENH_ROOT}/_bad_enh_backup/${seq}/$(basename "$enh")"
      fi
    done < "$VAL_RECON_LIST"
    CKPT="${GC2026_ROOT}/models/superpc_pretrained/kitti360_com.pth"
    RECON_ENH_CFG="${GC2026_ROOT}/output/full_n0_v2_recon_enh_config.json"
    PER_SEQ_ARGS=()
    [[ -f "$RECON_ENH_CFG" ]] && PER_SEQ_ARGS=(--per-seq-config "$RECON_ENH_CFG")
    "$PY" "${SCRIPT_DIR}/run_superpc_infer.py" \
      --cg-list "$VAL_RECON_LIST" \
      --ckpt-path "$CKPT" \
      --out-dir "$ENH_ROOT" \
      --num-points 11520 --target-num-points 46080 --sampling-steps 25 \
      --output-mode blend_cg --blend-voxel-mm 3.0 --adaptive-blend \
      --device cuda:0 \
      "${PER_SEQ_ARGS[@]}" \
      2>&1 | tee "${GC2026_ROOT}/output/stage1_backfill_superpc_val16.log"
    if [[ -s "$ALL88_LIST" ]]; then
      "$PY" "${SCRIPT_DIR}/run_superpc_infer.py" \
        --cg-list "$ALL88_LIST" \
        --ckpt-path "$CKPT" \
        --out-dir "$ENH_ROOT" \
        --num-points 11520 --target-num-points 46080 --sampling-steps 25 \
        --output-mode blend_cg --blend-voxel-mm 3.0 --adaptive-blend \
        --device cuda:0 --skip-existing \
        "${PER_SEQ_ARGS[@]}" \
        2>&1 | tee -a "${GC2026_ROOT}/output/stage1_backfill_superpc_all88.log"
    fi
  else
    echo "[backfill_fix] step2 no GPU — copy ENH from submission_candidate"
    "$PY" "${SCRIPT_DIR}/copy_enh_from_submission.py" \
      --recon-list "$VAL_RECON_LIST" \
      --out-json "${GC2026_ROOT}/output/stage1_backfill_enh_copy_val16.json"
    [[ -s "$ALL88_LIST" ]] && "$PY" "${SCRIPT_DIR}/copy_enh_from_submission.py" \
      --recon-list "$ALL88_LIST" \
      --out-json "${GC2026_ROOT}/output/stage1_backfill_enh_copy_all88.json"
  fi
fi

if [[ "$RUN_EVAL" == "1" ]]; then
  echo "[backfill_fix] step3 re-eval official val565 ENH..."
  "$PY" "${SCRIPT_DIR}/evaluate_uvg.py" \
    --pairs-file "$VAL_PAIRS" \
    --enhanced-root "$ENH_ROOT" \
    --n-samples "$N_SAMPLES" \
    --device "$EVAL_DEVICE" \
    --out-json "${ENH_ROOT}/evaluation_official_val_n20k_after_backfill_fix.json"

  echo "[backfill_fix] step4 Stage1 audit after fix..."
  "$PY" "${SCRIPT_DIR}/run_stage1_p0_audit.py" \
    --n-samples "$N_SAMPLES" \
    --out-json "${GC2026_ROOT}/output/stage1_p0_audit_after_fix.json"
fi

echo "[backfill_fix] DONE $(date -Is)"
