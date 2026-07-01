#!/usr/bin/env bash
# Master orchestrator: infer → refine/eval → fusion → temporal-attn fusion → review.
#
#   bash scripts/run_ft_val565_orchestrator.sh bg
#   bash scripts/show_ft_val565_orchestrator_progress.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORCH_ROOT="${ORCH_ROOT:-$ROOT/output/ft_val565_orchestrator}"
PDLTS_GEOM="${PDLTS_GEOM:-$ROOT/output/pdlts_finetune_uvg/val565/light}"
PDLTS_REFINE="${PDLTS_REFINE:-$ROOT/output/pdlts_finetune_uvg/val565_refine/pdlts_light_snap1_fill0.6_density}"
# Reuse full Enhancement-Only SuperPC cache (2155 frames; val565 subset complete).
SUPERPC_GEOM="${SUPERPC_GEOM:-$ROOT/output/submission_candidate}"
SKIP_SUPERPC_INFER="${SKIP_SUPERPC_INFER:-1}"
LOG="$ORCH_ROOT/logs/orchestrator.log"
STATUS="$ORCH_ROOT/orchestrator_status.json"
mkdir -p "$ORCH_ROOT/logs"

log() { echo "[orch] $(date +%H:%M:%S) $*" | tee -a "$LOG"; }

write_status() {
  local phase="$1"
  python3 - <<PY
import json, glob, os, time
status = {
    "updated": time.strftime("%Y-%m-%d %H:%M:%S"),
    "phase": "$phase",
    "pdlts_infer": len(glob.glob("$PDLTS_GEOM/*/*.ply")),
    "pdlts_refine_eval": os.path.isfile("$PDLTS_REFINE/evaluation_gc_baseline_val565.json"),
    "superpc_secondary": "$SUPERPC_GEOM",
    "superpc_infer_skipped": "$SKIP_SUPERPC_INFER" == "1",
    "superpc_infer": len(glob.glob("$SUPERPC_GEOM/*/*.ply")),
    "fusion_region_eval": os.path.isfile("$ROOT/output/ft_val565_fusion/region_hybrid_pdlts_superpc_snap1_fill0.6_density/evaluation_gc_baseline_val565.json"),
    "fusion_temporal_eval": os.path.isfile("$ROOT/output/ft_val565_fusion/temporal_region_hybrid_pdlts_superpc_snap1_fill0.6_density/evaluation_gc_baseline_val565.json"),
    "fusion_temporal_attn_eval": os.path.isfile("$ROOT/output/ft_val565_fusion/temporal_attn_hybrid_pdlts_superpc_snap1_fill0.6_density/evaluation_gc_baseline_val565.json"),
}
json.dump(status, open("$STATUS", "w"), indent=2)
PY
}

wait_ply() {
  local dir="$1" target="${2:-565}" proc_pat="$3"
  log "wait $proc_pat ($dir)"
  while true; do
    local n
    n=$(find "$dir" -name '*.ply' 2>/dev/null | wc -l)
    write_status "wait_${proc_pat}"
    log "  $proc_pat ${n}/${target}"
    [[ "$n" -ge "$target" ]] && return 0
    if ! pgrep -f "$proc_pat" >/dev/null 2>&1; then
      log "WARN: $proc_pat workers stopped at ${n}/${target}"
      return 0
    fi
    sleep 30
  done
}

wait_pdlts_pipeline() {
  log "wait existing PD-LTS fine-tune val565 pipeline (refine+eval)"
  while pgrep -f "run_pdlts_finetune_val565_pipeline.sh" >/dev/null 2>&1; do
    write_status "pdlts_pipeline_running"
    sleep 30
  done
  if [[ ! -f "$PDLTS_REFINE/evaluation_gc_baseline_val565.json" ]]; then
    log "PD-LTS pipeline exited without eval — running refine+eval"
    bash "$ROOT/scripts/run_pdlts_finetune_val565_pipeline.sh" refine || true
    bash "$ROOT/scripts/run_pdlts_finetune_val565_pipeline.sh" eval || true
  fi
}

run_all() {
  log "=== FT val565 orchestrator start ==="
  write_status "start"

  # Phase 1: PD-LTS GPU infer (existing pipeline)
  wait_ply "$PDLTS_GEOM" 565 "run_pdlts_infer.py.*pdlts_finetune_uvg/val565"
  write_status "pdlts_infer_done"

  # Phase 2: PD-LTS refine/eval (CPU). SuperPC secondary = submission_candidate (no re-infer).
  if [[ "$SKIP_SUPERPC_INFER" == "1" ]]; then
    log "skip SuperPC re-infer; secondary=$SUPERPC_GEOM (val565 subset verified)"
    local n_sc
    n_sc=$(find "$SUPERPC_GEOM" -name '*.ply' 2>/dev/null | wc -l)
    [[ "$n_sc" -ge 565 ]] || { log "ERROR: need >=565 PLY in $SUPERPC_GEOM (have $n_sc)"; exit 1; }
  else
    log "launch SuperPC val565 infer (GPU) || PD-LTS refine/eval (CPU)"
    bash "$ROOT/scripts/run_superpc_uvg_pipeline.sh" infer >> "$ORCH_ROOT/logs/superpc.log" 2>&1 &
    local spid=$!
    wait_pdlts_pipeline &
    local ppid=$!
    wait "$spid" || log "WARN superpc pipeline exit nonzero"
    wait "$ppid" || log "WARN pdlts pipeline exit nonzero"
    wait_ply "$SUPERPC_GEOM" 565 "run_superpc_infer.py.*superpc_uvg_pipeline"
  fi
  wait_pdlts_pipeline
  write_status "refine_eval_done"

  # Phase 3: fusion with fine-tuned weights (region + short-window temporal)
  log "fusion region + temporal hybrid"
  bash "$ROOT/scripts/run_ft_val565_fusion.sh" >> "$ORCH_ROOT/logs/fusion.log" 2>&1
  write_status "fusion_done"

  # Phase 4: temporal-attention hybrid (last; uses ft density as ENH history)
  log "temporal-attention hybrid (ENH history=$PDLTS_REFINE)"
  bash "$ROOT/scripts/run_ft_val565_temporal_attn.sh" >> "$ORCH_ROOT/logs/temporal_attn.log" 2>&1
  write_status "temporal_attn_done"

  # Phase 5: param review
  log "param review"
  source /root/miniconda3/etc/profile.d/conda.sh
  conda activate superpc
  python "$ROOT/scripts/review_ft_val565_params.py" | tee "$ORCH_ROOT/logs/review.log"
  write_status "done"
  log "=== orchestrator DONE ==="
  bash "$ROOT/scripts/show_ft_val565_orchestrator_progress.sh"
}

case "${1:-all}" in
  bg)
    nohup bash "$0" all >> "$LOG" 2>&1 &
    echo "[orch] pid=$! log=$LOG status=$STATUS"
    sleep 2
    bash "$ROOT/scripts/show_ft_val565_orchestrator_progress.sh"
    ;;
  all) run_all ;;
  status) bash "$ROOT/scripts/show_ft_val565_orchestrator_progress.sh" ;;
  *)
    echo "Usage: $0 {bg|all|status}" >&2
    exit 1
    ;;
esac
