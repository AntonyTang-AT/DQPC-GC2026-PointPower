#!/usr/bin/env bash
# Live dashboard for run_compliance_eval_plan.sh
GC2026_ROOT="${GC2026_ROOT:-/root/autodl-tmp/GC2026}"
LOG="${GC2026_ROOT}/output/compliance_eval_plan.log"
STATE="${GC2026_ROOT}/output/compliance_eval_plan.state"
FULL="${GC2026_ROOT}/output/full_pipeline_n0_v2_candidate"
ENH="${GC2026_ROOT}/output/submission_candidate"
SRC_TAR="${GC2026_ROOT}/output/GC2026_Team_submission_src.tar.gz"
SUMMARY="${GC2026_ROOT}/output/compliance_eval_summary.json"

check_file() {
  local label="$1" path="$2"
  if [[ -f "$path" ]]; then
    local sz
    sz=$(ls -lh "$path" 2>/dev/null | awk '{print $5}')
    echo "  [OK] $label ($sz)"
  else
    echo "  [..] $label"
  fi
}

while true; do
  clear
  echo "========== Compliance + Official Eval — $(date '+%Y-%m-%d %H:%M:%S') =========="
  if pgrep -f 'run_compliance_eval_plan.sh' >/dev/null 2>&1; then
    echo "Status: RUNNING (orchestrator)"
  elif pgrep -f 'post_full_pipeline.sh|post_submission_candidate.sh' >/dev/null 2>&1; then
    echo "Status: RUNNING (phase1 post)"
  elif pgrep -f 'evaluate_official_metric.py' >/dev/null 2>&1; then
    echo "Status: RUNNING (phase3 official metric)"
  elif pgrep -f 'apt-get.*docker|docker build|docker run' >/dev/null 2>&1; then
    echo "Status: RUNNING (docker install/build/smoke)"
  else
    echo "Status: STOPPED (or finished)"
  fi
  echo ""
  echo "--- Phases ---"
  grep -E '^phase|ALL_DONE' "$STATE" 2>/dev/null | tail -15 || echo "(no state yet)"
  if grep -q '^ALL_DONE=' "$STATE" 2>/dev/null; then
    echo "  >> 编排已结束，服务器将在 30s 内关机（若 SHUTDOWN_ON_DONE=1）"
  fi
  echo ""
  echo "--- Key artifacts ---"
  check_file "submission_src.tar.gz" "$SRC_TAR"
  check_file "full manifest.json" "$FULL/manifest.json"
  check_file "full runtime.log" "$FULL/runtime.log"
  check_file "enh manifest.json" "$ENH/manifest.json"
  check_file "full official_metric val565" "$FULL/evaluation_official_metric_val565.json"
  check_file "enh official_metric val565" "$ENH/evaluation_official_metric_val565.json"
  check_file "full official_val n20k" "$FULL/evaluation_official_val_n20k.json"
  check_file "enh official_val n20k" "$ENH/evaluation_official_val_n20k.json"
  check_file "compliance_summary.json" "$SUMMARY"
  echo ""
  echo "--- Active workers ---"
  pgrep -af 'run_compliance_eval|post_full|post_submission|evaluate_official_metric|evaluate_uvg|docker build|docker run|rgbd_to_cg' 2>/dev/null \
    | grep -v watch_compliance | sed 's|.*/scripts/||;s/ .*//' | sort -u | head -10 || echo "  (idle)"
  echo ""
  echo "--- Plan log (last 5) ---"
  tail -5 "$LOG" 2>/dev/null | sed 's/\r/\n/g' | tail -5 || echo "  (no log yet)"
  echo ""
  echo "--- Post logs (last 2 each) ---"
  echo "Full:"
  tail -2 "${GC2026_ROOT}/output/post_full_pipeline.log" 2>/dev/null | sed 's/^/  /' || true
  echo "Enh:"
  tail -2 "${GC2026_ROOT}/output/post_submission_candidate.log" 2>/dev/null | sed 's/^/  /' || true
  echo ""
  echo "Log:  tail -f $LOG"
  echo "Quit: Ctrl+C"
  sleep 10
done
