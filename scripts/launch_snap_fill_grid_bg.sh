#!/usr/bin/env bash
# Launch snap/fill grid in background + progress watcher.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRID="$ROOT/output/enh_refine_snap_fill_grid"
LOG="$GRID/snap_fill_grid.log"
PIDFILE="$GRID/grid.pid"
WATCH_PIDFILE="$GRID/watch.pid"

mkdir -p "$GRID"
date -u '+%Y-%m-%dT%H:%M:%SZ' > "$GRID/started_at.txt"
echo "FAST_GRID=${FAST_GRID:-0} PARALLEL=${PARALLEL_PRESETS:-1}" > "$GRID/mode.txt"

if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "Grid already running pid=$(cat "$PIDFILE")"
  bash "$ROOT/scripts/watch_snap_fill_grid.sh"
  exit 0
fi

nohup bash -c "
  cd '$ROOT'
  exec >> '$LOG' 2>&1
  echo '[launcher] snap/fill grid start \$(date) FAST_GRID=\${FAST_GRID:-0} PARALLEL=\${PARALLEL_PRESETS:-1}'
  EVAL_WORKERS=\${EVAL_WORKERS:-16} \
  FAST_GRID=\${FAST_GRID:-0} \
  PARALLEL_PRESETS=\${PARALLEL_PRESETS:-1} \
  PARALLEL_EVAL=\${PARALLEL_EVAL:-1} \
    bash scripts/run_enh_refine_snap_fill_grid.sh
  echo '[launcher] snap/fill grid DONE \$(date)'
" > /dev/null 2>&1 &

echo $! > "$PIDFILE"
echo "Started grid pid=$(cat "$PIDFILE") log=$LOG"

# progress watcher every 60s
if [[ ! -f "$WATCH_PIDFILE" ]] || ! kill -0 "$(cat "$WATCH_PIDFILE")" 2>/dev/null; then
  nohup bash -c "
    while kill -0 \$(cat '$PIDFILE') 2>/dev/null || pgrep -f run_enh_refine_snap_fill_grid >/dev/null; do
      bash '$ROOT/scripts/watch_snap_fill_grid.sh' > /dev/null
      sleep 60
    done
    bash '$ROOT/scripts/watch_snap_fill_grid.sh' > /dev/null
  " > "$GRID/watch.log" 2>&1 &
  echo $! > "$WATCH_PIDFILE"
fi

sleep 3
bash "$ROOT/scripts/watch_snap_fill_grid.sh"
