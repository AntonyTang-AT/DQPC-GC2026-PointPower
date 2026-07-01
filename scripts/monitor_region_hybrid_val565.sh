#!/usr/bin/env bash
# Poll region hybrid val565 progress every INTERVAL seconds.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INTERVAL="${INTERVAL:-60}"
while true; do
  bash "$ROOT/scripts/show_region_hybrid_progress.sh"
  sleep "$INTERVAL"
done
