#!/usr/bin/env bash
# GC2026 Full Pipeline entrypoint (organizer / Docker).
set -euo pipefail

GC2026_ROOT="${GC2026_ROOT:-/app}"
export GC2026_ROOT
cd "$GC2026_ROOT"

MODE="${1:-full}"
shift || true

case "$MODE" in
  full)
    exec bash "${GC2026_ROOT}/scripts/run_full_n0_v2.sh" "$@"
    ;;
  val-smoke)
    exec bash "${GC2026_ROOT}/scripts/run_official_val_smoke.sh" "$@"
    ;;
  post)
    exec bash "${GC2026_ROOT}/scripts/post_full_pipeline.sh" "$@"
    ;;
  install-cwipc)
    exec bash "${GC2026_ROOT}/scripts/install_cwipc.sh" "$@"
    ;;
  *)
    echo "Usage: $0 {full|val-smoke|post|install-cwipc}"
    exit 2
    ;;
esac
