#!/usr/bin/env bash
# Night autopilot: wait for grid → finalize → plan → optional 2155 → refresh report when FP done
set -euo pipefail

GC2026_ROOT="/root/autodl-tmp/GC2026"
GRID_ROOT="${GC2026_ROOT}/output/val_grid_official565"
LOG="${GRID_ROOT}/autopilot.log"
PROG="${GRID_ROOT}/progress.json"
GATE="${GRID_ROOT}/gate_decision.json"
FP_VS="${GC2026_ROOT}/output/full_pipeline_n0_v2_candidate/evaluation_gc_baseline_fp_val565_vs_baseline.json"
LOCK="${GRID_ROOT}/.autopilot.lock"

exec >>"$LOG" 2>&1

log() { echo "[$(date -Iseconds)] [autopilot] $*"; }

if [[ -f "$LOCK" ]]; then
  old_pid=$(cat "$LOCK" 2>/dev/null || echo "")
  if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
    log "Already running PID=$old_pid"
    exit 0
  fi
fi
echo $$ >"$LOCK"
trap 'rm -f "$LOCK"' EXIT

log "START night autopilot"

# ── 1) Ensure grid runner alive ──
if ! pgrep -f 'run_val_grid_official565_fast' >/dev/null; then
  if ! python3.12 -c "
import json,sys
p=json.load(open('${PROG}'))
sys.exit(0 if p.get('phase')=='done' else 1)
" 2>/dev/null; then
    log "Grid not running — restarting fast grid"
    cd "$GC2026_ROOT"
    export OMP_NUM_THREADS=2
    EVAL_WORKERS=6 nohup ./scripts/run_val_grid_official565_fast.sh >> "${GRID_ROOT}/run.log" 2>&1 &
  fi
fi

# ── 2) Ensure FP val565 eval alive ──
if [[ ! -f "$FP_VS" ]] && ! pgrep -f 'evaluate_full_pipeline_gc_baseline' >/dev/null; then
  if ! pgrep -f 'run_full_pipeline_gc_baseline_metrics.sh val565' >/dev/null; then
    log "FP eval not running — restarting val565 only"
    cd "$GC2026_ROOT"
    export OMP_NUM_THREADS=2
    GC_METRIC_WORKERS=6 nohup bash scripts/run_full_pipeline_gc_baseline_metrics.sh val565 \
      >> "${GC2026_ROOT}/output/full_pipeline_gc_baseline_eval.log" 2>&1 &
  fi
fi

# ── 3) Wait for grid completion ──
log "Waiting for fast grid (5 experiments)..."
while true; do
  if [[ -f "$GATE" ]]; then
    if python3.12 -c "
import json,sys
p=json.load(open('${PROG}'))
g=json.load(open('${GATE}'))
sys.exit(0 if p.get('phase')=='done' and p.get('experiment_total')==5 else 1)
" 2>/dev/null; then
      log "Grid DONE (gate + progress confirmed)"
      break
    fi
  fi
  if ! pgrep -f 'run_val_grid_official565_fast' >/dev/null; then
    if [[ -f "$GATE" ]]; then
      log "Grid process ended with gate_decision.json"
      break
    fi
    log "ERROR: grid died without gate — check run.log"
    exit 1
  fi
  sleep 60
done

# ── 4) Finalize metrics + morning report (fast grid) ──
log "Running finalize_morning_delivery.sh (fast grid)"
bash "${GC2026_ROOT}/scripts/finalize_morning_delivery.sh"

log "Running plan_next_steps.py (fast grid)"
python3.12 "${GC2026_ROOT}/scripts/plan_next_steps.py"

# ── 4b) Chamfer-tuned grid (new inference modes) ──
CHAMFER_DONE="${GRID_ROOT}/chamfer_tuned.done"
if [[ ! -f "$CHAMFER_DONE" ]]; then
  if ! pgrep -f 'run_val_grid_chamfer_tuned' >/dev/null; then
    log "Starting chamfer-tuned val565 grid (${TOTAL:-12} experiments)"
    cd "$GC2026_ROOT"
    export OMP_NUM_THREADS=2
    EVAL_WORKERS=4 nohup ./scripts/run_val_grid_chamfer_tuned.sh \
      >> "${GRID_ROOT}/chamfer_run.log" 2>&1 &
  fi
  log "Waiting for chamfer-tuned grid..."
  while true; do
    [[ -f "$CHAMFER_DONE" ]] && break
    if ! pgrep -f 'run_val_grid_chamfer_tuned' >/dev/null; then
      if [[ -f "$CHAMFER_DONE" ]]; then
        break
      fi
      log "WARN: chamfer grid exited without done marker — check chamfer_run.log"
      break
    fi
    sleep 120
  done
  if [[ -f "$CHAMFER_DONE" ]]; then
    log "Chamfer grid DONE — refreshing report"
    bash "${GC2026_ROOT}/scripts/finalize_morning_delivery.sh"
    python3.12 "${GC2026_ROOT}/scripts/plan_next_steps.py"
    python3.12 "${GC2026_ROOT}/scripts/build_morning_report.py"
  fi
else
  log "Chamfer tuned grid already complete"
fi

# ── 5) Post-gate follow-up (2155 if not vx3.0) ──
WINNER=$(python3.12 -c "import json; g=json.load(open('${GATE}')); print(g.get('best_experiment',''))")
BEST_MODE=$(python3.12 -c "import json; g=json.load(open('${GATE}')); print(g.get('best_config',{}).get('output_mode','blend_cg'))")
if [[ "$WINNER" == *"vx3.0"* ]] && [[ "$BEST_MODE" == "blend_cg" ]] && [[ "$WINNER" != *"adaptive"* ]] && [[ "$WINNER" != *"snap"* ]]; then
  log "Gate still vx3.0 blend_cg — skip 2155 re-infer (submission_candidate valid)"
else
  log "Gate changed to ${WINNER} (${BEST_MODE}) — starting 2155 re-infer"
  nohup bash "${GC2026_ROOT}/scripts/post_gate_2155_infer.sh" \
    >> "${GC2026_ROOT}/output/post_gate_2155_infer.log" 2>&1 &
fi

# ── 6) Wait for FP eval, refresh report ──
log "Waiting for FP val565 vs baseline (optional)..."
for _ in $(seq 1 360); do
  [[ -f "$FP_VS" ]] && break
  sleep 60
done
if [[ -f "$FP_VS" ]]; then
  log "FP eval done — refreshing MORNING_REPORT + NEXT_STEPS"
  python3.12 "${GC2026_ROOT}/scripts/build_morning_report.py"
  python3.12 "${GC2026_ROOT}/scripts/plan_next_steps.py"
else
  log "FP eval still running after wait — report will lack FP section until manual refresh"
fi

log "AUTOPILOT COMPLETE — see ${GRID_ROOT}/MORNING_REPORT.md and NEXT_STEPS.md"
