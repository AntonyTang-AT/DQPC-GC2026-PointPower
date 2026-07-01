#!/usr/bin/env bash
# Retry docker build + val-smoke; fallback to host-native val-smoke on nested AutoDL.
set -euo pipefail

GC2026_ROOT="${GC2026_ROOT:-/root/autodl-tmp/GC2026}"
DOCKER_IMAGE="${DOCKER_IMAGE:-gc2026-full-pipeline}"
STAGE1_JOBS="${STAGE1_JOBS:-3}"
BUILD_LOG="${GC2026_ROOT}/output/docker_build.log"
SMOKE_LOG="${GC2026_ROOT}/output/docker_val_smoke.log"
DOCKERD_LOG="${GC2026_ROOT}/output/dockerd.log"
RECON_HOST="${GC2026_ROOT}/output/docker_official_val_smoke"

start_dockerd() {
  if docker info >/dev/null 2>&1; then
    echo "[docker_retry] daemon already up"
    return 0
  fi
  echo "[docker_retry] starting dockerd (bridge=none, vfs)..."
  nohup dockerd --iptables=false --ip6tables=false --bridge=none --storage-driver=vfs \
    >>"$DOCKERD_LOG" 2>&1 &
  for _ in $(seq 1 30); do
    docker info >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "[docker_retry] ERROR: dockerd failed to start — see $DOCKERD_LOG"
  return 1
}

try_build() {
  local attempt
  for attempt in 1 2; do
    echo "[docker_retry] docker build attempt=$attempt $(date -Is)" | tee -a "$BUILD_LOG"
    if docker build -t "$DOCKER_IMAGE" "$GC2026_ROOT" >>"$BUILD_LOG" 2>&1; then
      echo "[docker_retry] build OK"
      return 0
    fi
    tail -3 "$BUILD_LOG" | sed 's/^/  /'
    [[ "$attempt" -lt 2 ]] && sleep 30
  done
  return 1
}

run_docker_smoke() {
  mkdir -p "$RECON_HOST"
  docker run --rm --network=host \
    -v "${GC2026_ROOT}/data/raw:/app/data/raw:ro" \
    -v "${RECON_HOST}:/app/output/official_val_n0_v2_recon" \
    -e GC2026_ROOT=/app \
    -e STAGE1_JOBS="$STAGE1_JOBS" \
    "$DOCKER_IMAGE" val-smoke >>"$SMOKE_LOG" 2>&1
}

run_native_smoke() {
  echo "[docker_retry] FALLBACK host-native val-smoke $(date -Is)" | tee -a "$SMOKE_LOG"
  export GC2026_ROOT RECON_ROOT="$RECON_HOST" STAGE1_JOBS
  # shellcheck source=/dev/null
  [[ -f "${GC2026_ROOT}/output/cwipc_env.sh" ]] && source "${GC2026_ROOT}/output/cwipc_env.sh"
  bash "${GC2026_ROOT}/scripts/run_official_val_smoke.sh" >>"$SMOKE_LOG" 2>&1
}

main() {
  BUILD_OK=0
  if start_dockerd && try_build; then
    BUILD_OK=1
  else
    echo "[docker_retry] build failed — nested container often blocks 'unshare'" | tee -a "$BUILD_LOG"
    echo "[docker_retry] build on a privileged VM: docker build -t $DOCKER_IMAGE ." | tee -a "$BUILD_LOG"
  fi

  local attempt
  for attempt in 1 2; do
    echo "[docker_retry] val-smoke attempt=$attempt $(date -Is)" | tee -a "$SMOKE_LOG"
    if [[ "$BUILD_OK" == "1" ]]; then
      run_docker_smoke && { echo "[docker_retry] docker val-smoke OK"; exit 0; }
    fi
    run_native_smoke && { echo "[docker_retry] native val-smoke OK"; exit 0; }
    [[ "$attempt" -lt 2 ]] && sleep 30
  done
  echo "[docker_retry] val-smoke failed after 2 attempts"
  exit 1
}

main "$@"
