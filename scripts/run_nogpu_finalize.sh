#!/usr/bin/env bash
# CPU-only finalize: promote backfill eval, re-eval, manifests, submission sync, reports.
set -euo pipefail

GC2026_ROOT="${GC2026_ROOT:-/root/autodl-tmp/GC2026}"
SCRIPT_DIR="${GC2026_ROOT}/scripts"
PY="${PY:-python3.12}"
LOG="${GC2026_ROOT}/output/nogpu_finalize.log"
FULL_OUT="${GC2026_ROOT}/output/full_pipeline_n0_v2_candidate"
ENH_OUT="${GC2026_ROOT}/output/submission_candidate"
RECON_ROOT="${GC2026_ROOT}/output/full_pipeline_n0_v2_cg"
VAL_PAIRS="${GC2026_ROOT}/data/processed/val_pairs_official_cgv2.txt"
VAL_CG="${GC2026_ROOT}/data/processed/val_cg_only_official_cgv2.txt"
GATE_JSON="${GC2026_ROOT}/output/val_grid/gate_decision.json"
N_SAMPLES="${N_SAMPLES:-5000}"
METRIC_POINTS="${METRIC_POINTS:-20000}"

exec > >(tee -a "$LOG") 2>&1
echo "[nogpu_finalize] START $(date -Is)"

source "${SCRIPT_DIR}/env_setup.sh"

step() { echo "[nogpu_finalize] === $* $(date +%H:%M:%S) ==="; }

# 1) Promote backfill eval to primary
step "promote backfill eval"
AFTER="${FULL_OUT}/evaluation_official_val_n20k_after_backfill_fix.json"
if [[ -f "$AFTER" ]]; then
  cp -f "$AFTER" "${FULL_OUT}/evaluation_official_val_n20k.json"
  cp -f "$AFTER" "${FULL_OUT}/evaluation_val_n20k.json"
  echo "promoted after_backfill_fix -> primary"
else
  echo "WARN: $AFTER missing, keep existing primary eval"
fi

# 2) Per-sequence summary
step "per-sequence summary"
"$PY" "${SCRIPT_DIR}/summarize_eval_by_sequence.py" \
  --eval-json "${FULL_OUT}/evaluation_official_val_n20k.json" \
  --out-json "${GC2026_ROOT}/output/enhancement_eval/per_sequence_full_pipeline_official_val.json" \
  || true
"$PY" "${SCRIPT_DIR}/summarize_eval_by_sequence.py" \
  --eval-json "${ENH_OUT}/evaluation_official_val_n20k.json" \
  --out-json "${GC2026_ROOT}/output/enhancement_eval/per_sequence_enhancement_official_val.json" \
  || true

# 3) Official metric (CPU, both tracks — Full uses post-backfill ENH)
step "official metric Full"
"$PY" "${SCRIPT_DIR}/evaluate_official_metric.py" \
  --enhanced-root "$FULL_OUT" \
  --pairs-file "$VAL_PAIRS" \
  --max-points "$METRIC_POINTS" \
  --also-cg \
  --out-json "${FULL_OUT}/evaluation_official_metric_val565.json"

step "official metric Enh (skip if exists)"
if [[ ! -f "${ENH_OUT}/evaluation_official_metric_val565.json" ]]; then
  "$PY" "${SCRIPT_DIR}/evaluate_official_metric.py" \
    --enhanced-root "$ENH_OUT" \
    --pairs-file "$VAL_PAIRS" \
    --max-points "$METRIC_POINTS" \
    --also-cg \
    --out-json "${ENH_OUT}/evaluation_official_metric_val565.json"
fi

# 4) Recon pipeline eval (official val565: recon paths derived from CG pairs)
step "build recon-he pairs for official val"
RECON_VAL_PAIRS="${GC2026_ROOT}/output/full_pipeline_n0_v2_cg/recon_he_pairs_official_val565.txt"
"$PY" <<PY
import os, sys
sys.path.insert(0, "${SCRIPT_DIR}")
from compare_reconstructed_cg import recon_path_from_cg
recon_root = "${RECON_ROOT}"
out = "${RECON_VAL_PAIRS}"
lines = []
for ln in open("${VAL_PAIRS}"):
    ln = ln.strip()
    if not ln: continue
    parts = ln.split("\t")
    if len(parts) < 2: continue
    cg, he = parts[0], parts[1]
    recon = recon_path_from_cg(cg, recon_root)
    if os.path.isfile(recon) and os.path.isfile(he):
        lines.append(f"{recon}\t{he}")
open(out, "w").write("\n".join(lines) + ("\n" if lines else ""))
print(f"recon-he pairs: {len(lines)}")
PY

step "recon pipeline eval"
"$PY" "${SCRIPT_DIR}/evaluate_recon_pipeline.py" \
  --recon-list "${RECON_ROOT}/reconstructed_cg_list.txt" \
  --pairs-file "$RECON_VAL_PAIRS" \
  --enhanced-root "$FULL_OUT" \
  --n-samples "$N_SAMPLES" \
  --device cpu \
  --out-json "${FULL_OUT}/evaluation_recon_pipeline_official_val.json" \
  || true

# 5) Native gate (official val565)
step "native gate recon"
"$PY" "${SCRIPT_DIR}/eval_native_gate.py" \
  --recon-root "$RECON_ROOT" \
  --cg-list "$VAL_CG" \
  --n-samples "$N_SAMPLES" \
  --out-json "${RECON_ROOT}/native_gate_official_val565.json"

step "native gate enh"
"$PY" "${SCRIPT_DIR}/eval_native_gate.py" \
  --recon-root "$RECON_ROOT" \
  --enh-root "$FULL_OUT" \
  --cg-list "$VAL_CG" \
  --n-samples "$N_SAMPLES" \
  --out-json "${FULL_OUT}/native_gate_enh_official_val565.json"

# 6) Color + temporal (official val only)
step "color eval official val"
"$PY" "${SCRIPT_DIR}/evaluate_color.py" \
  --pairs-file "$VAL_PAIRS" \
  --enhanced-root "$FULL_OUT" \
  --out-json "${FULL_OUT}/color_evaluation_official_val565.json" \
  || true

step "temporal stability"
"$PY" "${SCRIPT_DIR}/evaluate_temporal.py" \
  --enhanced-root "$FULL_OUT" \
  --out-json "${FULL_OUT}/temporal_stability_official_val565.json" \
  || true

# 7) Manifests
step "manifests"
"$PY" "${SCRIPT_DIR}/make_submission.py" \
  --enhanced-dir "$ENH_OUT" \
  --team "GC2026 Team" \
  --processing-track "Enhancement Only" \
  --title "UVG-CWI-DQPC GC2026 Enhancement Only SuperPC" \
  --post-processing "$GATE_JSON" \
  --cg-version v2 \
  --cg-source official \
  --data-split "official_val=TrumanShow,VictoryHeart,VirtualLife"

"$PY" "${SCRIPT_DIR}/make_submission.py" \
  --enhanced-dir "$FULL_OUT" \
  --team "GC2026 Team" \
  --processing-track "Full Pipeline" \
  --title "UVG-CWI-DQPC GC2026 Full Pipeline N0 v2 SuperPC" \
  --post-processing "$GATE_JSON" \
  --cg-version v2 \
  --cg-source reconstructed \
  --stage1-tag N0_cwipc_official \
  --data-split "official_val=TrumanShow,VictoryHeart,VirtualLife" \
  --pipeline-notes "RGBD bag -> cwipc-native Stage1 (N0) + SuperPC; 88-frame backfill official CG fallback"

# 8) infer_meta + runtime
step "rebuild infer_meta"
"$PY" "${SCRIPT_DIR}/rebuild_infer_meta_from_enh.py" \
  --enh-root "$FULL_OUT" \
  --recon-root "$RECON_ROOT" \
  --timing-json "${ENH_OUT}/infer_meta.json"

step "runtime summary"
"$PY" "${SCRIPT_DIR}/write_runtime_summary.py" \
  --out-dir "$FULL_OUT" \
  --team "GC2026 Team" || true
"$PY" "${SCRIPT_DIR}/write_runtime_summary.py" \
  --out-dir "$ENH_OUT" \
  --team "GC2026 Team" || true

# 9) Submission repo sync + tar
step "prepare submission repo"
bash "${SCRIPT_DIR}/prepare_submission_repo.sh"

step "submission src tar"
tar -czf "${GC2026_ROOT}/output/GC2026_Team_submission_src.tar.gz" \
  -C "$GC2026_ROOT" submissions/GC2026_Team
ls -lh "${GC2026_ROOT}/output/GC2026_Team_submission_src.tar.gz"

# 10) Compliance summary + status report + integrity
step "compliance summary"
"$PY" "${SCRIPT_DIR}/refresh_compliance_summary.py"

step "status report"
"$PY" "${SCRIPT_DIR}/generate_status_report.py" || true

step "integrity check"
bash "${SCRIPT_DIR}/check_integrity.sh" | tee "${GC2026_ROOT}/output/integrity_check_latest.log" || true

step "DONE $(date -Is)"
