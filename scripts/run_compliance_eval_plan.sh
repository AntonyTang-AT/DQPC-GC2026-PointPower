#!/usr/bin/env bash
# Compliance + official eval: resume-aware, parallel waves, docker, auto-shutdown.
set -euo pipefail

GC2026_ROOT="${GC2026_ROOT:-/root/autodl-tmp/GC2026}"
LOG="${GC2026_ROOT}/output/compliance_eval_plan.log"
STATE="${GC2026_ROOT}/output/compliance_eval_plan.state"
LOCK="${GC2026_ROOT}/output/compliance_eval_plan.lock"
PY="${PY:-python3.12}"
DOCKER_IMAGE="${DOCKER_IMAGE:-gc2026-full-pipeline}"
MIN_DISK_GB="${MIN_DISK_GB:-30}"
STAGE1_JOBS="${STAGE1_JOBS:-3}"
N_SAMPLES="${N_SAMPLES:-20000}"
EVAL_DEVICE="${EVAL_DEVICE:-cpu}"
SHUTDOWN_ON_DONE="${SHUTDOWN_ON_DONE:-1}"
MAX_RUNTIME_HOURS="${MAX_RUNTIME_HOURS:-5}"
SKIP_FULL_UVG="${SKIP_FULL_UVG:-1}"

FULL_OUT="${GC2026_ROOT}/output/full_pipeline_n0_v2_candidate"
ENH_OUT="${GC2026_ROOT}/output/submission_candidate"
VAL_PAIRS="${GC2026_ROOT}/data/processed/val_pairs_official_cgv2.txt"
SRC_TAR="${GC2026_ROOT}/output/GC2026_Team_submission_src.tar.gz"
SUMMARY="${GC2026_ROOT}/output/compliance_eval_summary.json"
ENH_VAL_JSON="${ENH_OUT}/evaluation_official_val_n20k.json"
FULL_VAL_JSON="${FULL_OUT}/evaluation_official_val_n20k.json"
ENH_METRIC_JSON="${ENH_OUT}/evaluation_official_metric_val565.json"
FULL_METRIC_JSON="${FULL_OUT}/evaluation_official_metric_val565.json"

PLAN_START=$(date +%s)
MAX_RUNTIME_SECS=$((MAX_RUNTIME_HOURS * 3600))
DEADLINE_EPOCH=$((PLAN_START + MAX_RUNTIME_SECS))
WATCHDOG_PID=""
FINALIZED=0

exec > >(tee -a "$LOG") 2>&1

mark() {
  echo "$1=$(date -Is)" >>"$STATE"
  echo "[compliance_plan] $1"
}

state_has() {
  grep -qE "^${1}=" "$STATE" 2>/dev/null
}

avail_gb() {
  df -BG /root/autodl-tmp 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$4); print $4}' || echo 0
}

json_ok() {
  local path="$1" min_frames="${2:-500}"
  [[ -f "$path" ]] || return 1
  "$PY" -c "
import json, sys
d = json.load(open('$path'))
s = d.get('summary') or d
n = s.get('n_frames') or s.get('n_pairs') or len(d.get('per_frame', d.get('frames', [])))
sys.exit(0 if n >= $min_frames else 1)
" 2>/dev/null
}

workers_running() {
  pgrep -f 'evaluate_uvg\.py|evaluate_official_metric\.py|docker build|docker run.*gc2026' >/dev/null 2>&1
}

kill_workers() {
  pkill -f 'evaluate_uvg\.py.*evaluation_official_val_n20k' 2>/dev/null || true
  pkill -f 'evaluate_official_metric\.py' 2>/dev/null || true
  pkill -f "docker build.*${DOCKER_IMAGE}" 2>/dev/null || true
  pkill -f "docker run.*${DOCKER_IMAGE}" 2>/dev/null || true
  sleep 3
}

check_deadline() {
  if (( $(date +%s) >= DEADLINE_EPOCH )); then
    echo "[compliance_plan] ERROR: MAX_RUNTIME ${MAX_RUNTIME_HOURS}h exceeded"
    return 1
  fi
  return 0
}

write_summary() {
  local reason="${1:-normal}"
  "$PY" <<PY
import json, os
from datetime import datetime

root = "${GC2026_ROOT}"
reason = "${reason}"

def load(p):
    if os.path.isfile(p):
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    return None

def pick_summary(path):
    d = load(path)
    if not d:
        return None
    return d.get("summary", d)

state = {}
if os.path.isfile("${STATE}"):
    for ln in open("${STATE}"):
        if "=" in ln.strip():
            k, v = ln.strip().split("=", 1)
            state[k] = v

out = {
    "generated_at": datetime.utcnow().isoformat() + "Z",
    "finish_reason": reason,
    "max_runtime_hours": ${MAX_RUNTIME_HOURS},
    "plan_state": state,
    "artifacts": {
        "submission_src_tar": "${SRC_TAR}" if os.path.isfile("${SRC_TAR}") else None,
        "full_manifest": f"{root}/output/full_pipeline_n0_v2_candidate/manifest.json",
        "enh_manifest": f"{root}/output/submission_candidate/manifest.json",
        "full_official_metric": "${FULL_METRIC_JSON}" if os.path.isfile("${FULL_METRIC_JSON}") else None,
        "enh_official_metric": "${ENH_METRIC_JSON}" if os.path.isfile("${ENH_METRIC_JSON}") else None,
    },
    "metrics": {
        "enh_official_uvg": pick_summary("${ENH_VAL_JSON}"),
        "full_official_uvg": pick_summary("${FULL_VAL_JSON}"),
        "enh_official_metric": pick_summary("${ENH_METRIC_JSON}"),
        "full_official_metric": pick_summary("${FULL_METRIC_JSON}"),
    },
}
json.dump(out, open("${SUMMARY}", "w"), indent=2)
print(f"[compliance_plan] summary -> ${SUMMARY} reason={reason}")
PY
}

do_shutdown() {
  local reason="$1"
  if [[ "$SHUTDOWN_ON_DONE" != "1" ]]; then
    echo "[compliance_plan] SHUTDOWN_ON_DONE=0 — skip shutdown ($reason)"
    return 0
  fi
  echo "[compliance_plan] shutdown in 30s ($reason)"
  sleep 30
  shutdown -h now 2>/dev/null || poweroff 2>/dev/null || init 0 || true
}

finalize_and_shutdown() {
  local reason="${1:-normal}"
  if [[ "$FINALIZED" == "1" ]]; then
    return 0
  fi
  FINALIZED=1
  [[ -n "$WATCHDOG_PID" ]] && kill "$WATCHDOG_PID" 2>/dev/null || true

  echo "[compliance_plan] finalize reason=$reason"
  local wait_sec=0
  while workers_running && [[ "$wait_sec" -lt 300 ]]; do
    echo "[compliance_plan] waiting for workers (${wait_sec}s)..."
    sleep 10
    wait_sec=$((wait_sec + 10))
  done
  if workers_running; then
    echo "[compliance_plan] force kill remaining workers"
    kill_workers
  fi

  write_summary "$reason"
  if ! state_has "ALL_DONE"; then
    mark "ALL_DONE"
  fi
  echo "[compliance_plan] END $(date -Is) reason=$reason"
  echo "[compliance_plan] deadline was $(date -d "@${DEADLINE_EPOCH}" -Is 2>/dev/null || date -r "$DEADLINE_EPOCH" -Is 2>/dev/null || echo "@${DEADLINE_EPOCH}")"
  do_shutdown "$reason"
}

deadline_watchdog() {
  while sleep 30; do
    if (( $(date +%s) >= DEADLINE_EPOCH )); then
      echo "[compliance_plan] WATCHDOG: max runtime ${MAX_RUNTIME_HOURS}h reached"
      kill_workers
      finalize_and_shutdown "timeout_max_runtime_${MAX_RUNTIME_HOURS}h"
      exit 124
    fi
  done
}

on_exit() {
  local code=$?
  if [[ "$FINALIZED" == "1" ]]; then
    return 0
  fi
  if [[ "$code" -ne 0 ]]; then
    finalize_and_shutdown "exit_code_${code}"
  elif ! workers_running; then
    finalize_and_shutdown "orchestrator_exit_idle"
  fi
}
trap on_exit EXIT

run_eval_uvg() {
  local track="$1" out_root="$2" out_json="$3"
  check_deadline || return 1
  echo "[compliance_plan] eval_uvg track=$track pairs=565"
  "$PY" "${GC2026_ROOT}/scripts/evaluate_uvg.py" \
    --pairs-file "$VAL_PAIRS" \
    --enhanced-root "$out_root" \
    --n-samples "$N_SAMPLES" \
    --device "$EVAL_DEVICE" \
    --out-json "$out_json"
  cp -f "$out_json" "${out_root}/evaluation_val_n20k.json" 2>/dev/null || true
}

run_metric() {
  local track="$1" out_root="$2" out_json="$3"
  check_deadline || return 1
  echo "[compliance_plan] official_metric track=$track"
  "$PY" "${GC2026_ROOT}/scripts/evaluate_official_metric.py" \
    --enhanced-root "$out_root" \
    --pairs-file "$VAL_PAIRS" \
    --also-cg \
    --out-json "$out_json"
}

install_docker_if_missing() {
  if command -v docker >/dev/null 2>&1; then
    return 0
  fi
  echo "[compliance_plan] installing docker.io..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq docker.io
  systemctl start docker 2>/dev/null || service docker start 2>/dev/null || true
  command -v docker >/dev/null 2>&1
}

docker_build_with_retry() {
  local attempt log="${GC2026_ROOT}/output/docker_build.log"
  for attempt in 1 2; do
    check_deadline || return 1
    echo "[compliance_plan] docker build attempt=$attempt"
    if docker build -t "$DOCKER_IMAGE" "${GC2026_ROOT}" >>"$log" 2>&1; then
      return 0
    fi
    echo "[compliance_plan] docker build failed attempt=$attempt"
    [[ "$attempt" -lt 2 ]] && sleep 30
  done
  return 1
}

docker_smoke_with_retry() {
  local attempt log="${GC2026_ROOT}/output/docker_val_smoke.log"
  local recon_host="${GC2026_ROOT}/output/docker_official_val_smoke"
  mkdir -p "$recon_host"
  for attempt in 1 2; do
    check_deadline || return 1
    echo "[compliance_plan] docker val-smoke attempt=$attempt"
    if docker run --rm \
      -v "${GC2026_ROOT}/data/raw:/app/data/raw:ro" \
      -v "${recon_host}:/app/output/official_val_n0_v2_recon" \
      -e GC2026_ROOT=/app \
      -e STAGE1_JOBS="$STAGE1_JOBS" \
      "$DOCKER_IMAGE" val-smoke \
      >>"$log" 2>&1; then
      return 0
    fi
    echo "[compliance_plan] docker val-smoke failed attempt=$attempt"
    [[ "$attempt" -lt 2 ]] && sleep 30
  done
  return 1
}

phase1_post_done() {
  [[ -f "${ENH_OUT}/manifest.json" && -f "${ENH_OUT}/runtime.log" \
    && -f "${FULL_OUT}/manifest.json" && -f "${FULL_OUT}/runtime.log" ]]
}

main() {
  mkdir -p "${GC2026_ROOT}/output"
  touch "$STATE"
  exec 9>"$LOCK"
  if ! flock -n 9; then
    echo "[compliance_plan] another runner active — exit"
    exit 0
  fi

  deadline_watchdog &
  WATCHDOG_PID=$!

  echo "=============================================="
  echo "[compliance_plan] START $(date -Is)"
  echo "[compliance_plan] MAX_RUNTIME=${MAX_RUNTIME_HOURS}h deadline=$(date -d "@${DEADLINE_EPOCH}" -Is 2>/dev/null || echo "@${DEADLINE_EPOCH}")"
  echo "[compliance_plan] log=$LOG"
  echo "=============================================="

  if ! state_has "phase0=done"; then
    mark "phase0_begin"
    agb=$(avail_gb)
    echo "[compliance_plan] disk_avail_gb=$agb (min=$MIN_DISK_GB)"
    if [[ "${agb%%.*}" -lt "$MIN_DISK_GB" ]]; then
      echo "[compliance_plan] ERROR: disk low"
      exit 1
    fi
    for d in "$FULL_OUT" "$ENH_OUT"; do
      n=$(find "$d" -name '*.ply' 2>/dev/null | wc -l)
      echo "[compliance_plan] $d ply=$n"
    done
    if [[ ! -f "$VAL_PAIRS" ]]; then
      "$PY" "${GC2026_ROOT}/scripts/build_split_pairs.py"
    fi
    mark "phase0=done"
  fi

  # Phase1: post artifacts (skip if present) + official val565 eval only
  if phase1_post_done; then
    state_has "phase1_post=done" || mark "phase1_post=done"
  else
    mark "phase1_post_begin"
    export PACK_TAR=0 RUN_SMOOTH=0 SKIP_FULL_UVG=1 UVG_VAL_PAIRS_FILE="$VAL_PAIRS"
    (
      OUT_DIR="$FULL_OUT" RECON_ROOT="${GC2026_ROOT}/output/full_pipeline_n0_v2_cg" \
        bash "${GC2026_ROOT}/scripts/post_full_pipeline.sh"
    ) &
    PID_FULL=$!
    (
      OUT_DIR="$ENH_OUT" bash "${GC2026_ROOT}/scripts/post_submission_candidate.sh"
    ) &
    PID_ENH=$!
    wait "$PID_FULL" "$PID_ENH" || echo "[compliance_plan] WARN: post partial failure"
    mark "phase1_post=done"
  fi

  # Wave1: parallel official val565 eval + tar pack + docker build start
  PIDS=()
  if ! json_ok "$ENH_VAL_JSON" 500; then
    ( run_eval_uvg enh "$ENH_OUT" "$ENH_VAL_JSON" && mark "phase1_eval_enh=done" ) &
    PIDS+=($!)
  else
    state_has "phase1_eval_enh=done" || mark "phase1_eval_enh=done"
  fi

  if ! json_ok "$FULL_VAL_JSON" 500; then
    ( run_eval_uvg full "$FULL_OUT" "$FULL_VAL_JSON" && mark "phase1_eval_full=done" ) &
    PIDS+=($!)
  else
    state_has "phase1_eval_full=done" || mark "phase1_eval_full=done"
  fi

  if ! state_has "phase2=done"; then
    (
      mark "phase2_begin"
      tar -czf "$SRC_TAR" -C "${GC2026_ROOT}" submissions/GC2026_Team
      ls -lh "$SRC_TAR"
      mark "phase2=done"
    ) &
    PIDS+=($!)
  fi

  DOCKER_BUILD_PID=""
  if ! state_has "phase4=done" && ! state_has "phase4=failed"; then
    (
      mark "phase4_begin"
      if install_docker_if_missing && docker_build_with_retry; then
        mark "phase4=done"
      else
        echo "[compliance_plan] WARN: docker build failed"
        mark "phase4=failed"
      fi
    ) &
    DOCKER_BUILD_PID=$!
    PIDS+=($DOCKER_BUILD_PID)
  fi

  for pid in "${PIDS[@]}"; do
    wait "$pid" || echo "[compliance_plan] WARN: wave1 job $pid failed"
  done
  state_has "phase1=done" || mark "phase1=done"

  check_deadline || { finalize_and_shutdown "timeout_before_phase3"; exit 124; }

  # Wave2: parallel official metric
  PIDS=()
  if ! json_ok "$ENH_METRIC_JSON" 500; then
    ( run_metric enh "$ENH_OUT" "$ENH_METRIC_JSON" && mark "phase3_enh=done" ) &
    PIDS+=($!)
  else
    state_has "phase3_enh=done" || mark "phase3_enh=done"
  fi

  if ! json_ok "$FULL_METRIC_JSON" 500; then
    ( run_metric full "$FULL_OUT" "$FULL_METRIC_JSON" && mark "phase3_full=done" ) &
    PIDS+=($!)
  else
    state_has "phase3_full=done" || mark "phase3_full=done"
  fi

  for pid in "${PIDS[@]}"; do
    wait "$pid" || echo "[compliance_plan] WARN: metric job $pid failed"
  done
  state_has "phase3=done" || mark "phase3=done"

  check_deadline || { finalize_and_shutdown "timeout_before_phase5"; exit 124; }

  # Wave3: docker val-smoke (wait for build if still running)
  if [[ -n "$DOCKER_BUILD_PID" ]]; then
    wait "$DOCKER_BUILD_PID" 2>/dev/null || true
  fi

  if ! state_has "phase5=done" && ! state_has "phase5=failed"; then
    mark "phase5_begin"
    if state_has "phase4=done" && command -v docker >/dev/null 2>&1; then
      if docker_smoke_with_retry; then
        mark "phase5=done"
      else
        echo "[compliance_plan] WARN: docker val-smoke failed"
        mark "phase5=failed"
      fi
    else
      echo "[compliance_plan] skip phase5 (no docker image)"
      mark "phase5=failed"
    fi
  fi

  finalize_and_shutdown "success"
}

main "$@"
