#!/usr/bin/env bash
# Re-run all 3 ft fusion presets in parallel (fine-tune PD-LTS primary, CPU-only).
#
#   bash scripts/run_ft_val565_fusion_parallel.sh bg
#   bash scripts/show_ft_val565_fusion_parallel_progress.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRID="${GRID_ROOT:-$ROOT/output/ft_val565_fusion}"
PDLTS_GEOM="${PDLTS_GEOM:-$ROOT/output/pdlts_finetune_uvg/val565/light}"
PDLTS_REFINE="${PDLTS_REFINE:-$ROOT/output/pdlts_finetune_uvg/val565_refine/pdlts_light_snap1_fill0.6_density}"
SUPERPC_GEOM="${SUPERPC_GEOM:-$ROOT/output/submission_candidate}"
LOGDIR="${LOGDIR:-$GRID/logs/parallel_rerun}"
STATUS="${STATUS:-$GRID/parallel_rerun_status.json}"
FORCE_RERUN="${FORCE_RERUN:-1}"
PRESET_JOBS="${PRESET_JOBS:-3}"

# shellcheck source=cpu_parallel_defaults.sh
source "$ROOT/scripts/cpu_parallel_defaults.sh"

PRESETS=(
  region_hybrid_pdlts_superpc_snap1_fill0.6_density
  temporal_region_hybrid_pdlts_superpc_snap1_fill0.6_density
  temporal_attn_hybrid_pdlts_superpc_snap1_fill0.6_density
)

mkdir -p "$LOGDIR"

log() { echo "[ft_fusion_par] $(date +%H:%M:%S) $*"; }

write_status() {
  local phase="$1"
  python3 - "$phase" "$STATUS" "$GRID" <<'PY'
import glob, json, os, sys, time
phase, status_path, grid = sys.argv[1:4]
presets = [
    "region_hybrid_pdlts_superpc_snap1_fill0.6_density",
    "temporal_region_hybrid_pdlts_superpc_snap1_fill0.6_density",
    "temporal_attn_hybrid_pdlts_superpc_snap1_fill0.6_density",
]
st = {"updated": time.strftime("%Y-%m-%d %H:%M:%S"), "phase": phase, "presets": {}}
for p in presets:
    d = os.path.join(grid, p)
    n = len(glob.glob(os.path.join(d, "*", "*.ply")))
    ev = os.path.join(d, "evaluation_gc_baseline_val565.json")
    st["presets"][p] = {"ply": n, "eval": os.path.isfile(ev)}
json.dump(st, open(status_path, "w"), indent=2)
PY
}

preflight() {
  local n_p n_s n_h
  n_p=$(find "$PDLTS_GEOM" -name '*.ply' 2>/dev/null | wc -l)
  n_s=$(find "$SUPERPC_GEOM" -name '*.ply' 2>/dev/null | wc -l)
  n_h=$(find "$PDLTS_REFINE" -name '*.ply' 2>/dev/null | wc -l)
  [[ "$n_p" -ge 565 && "$n_s" -ge 565 && "$n_h" -ge 565 ]] || {
    log "blocked: pdlts=${n_p} superpc=${n_s} history=${n_h} (need 565 each)"
    exit 1
  }
  log "primary=$PDLTS_GEOM"
  log "secondary=$SUPERPC_GEOM"
  log "enh_history=$PDLTS_REFINE"
  log "NUM_SHARDS=$NUM_SHARDS EVAL_WORKERS=$EVAL_WORKERS (CPU-only, no GPU)"
}

launch_one() {
  local preset="$1"
  local out="$GRID/$preset"
  local log="$LOGDIR/${preset}.log"
  local extra_env=()
  if [[ "$preset" == *temporal_attn* ]]; then
    extra_env+=(ENH_HISTORY_DIR="$PDLTS_REFINE")
  fi
  log "launch $preset -> $log"
  env FORCE_RERUN="$FORCE_RERUN" PRESET="$preset" OUT_DIR="$out" \
    GEOMETRY_DIR="$PDLTS_GEOM" GEOMETRY_SECONDARY_DIR="$SUPERPC_GEOM" \
    NUM_SHARDS="$NUM_SHARDS" EVAL_WORKERS="$EVAL_WORKERS" \
    LOGDIR="$LOGDIR/$preset" \
    CG_LIST="$ROOT/data/processed/val_cg_only_official_cgv2.txt" \
    "${extra_env[@]}" \
    bash "$ROOT/scripts/run_ft_fusion_one.sh" >> "$log" 2>&1 &
  echo "$!"
}

run_all() {
  log "=== ft fusion parallel rerun (PRESET_JOBS=$PRESET_JOBS, NPROC=$NPROC) ==="
  preflight
  write_status "running"

  monitor_loop() {
    while true; do
      sleep 30
      if ! pgrep -f "run_ft_fusion_one.sh" >/dev/null 2>&1 \
        && ! pgrep -f "run_enh_refine_infer.py.*ft_val565_fusion" >/dev/null 2>&1 \
        && ! pgrep -f "evaluate_gc_baseline_metrics.py.*ft_val565_fusion" >/dev/null 2>&1; then
        break
      fi
      write_status "running"
    done
  }
  monitor_loop &
  local mon_pid=$!

  PIDS=()
  for preset in "${PRESETS[@]}"; do
    PIDS+=("$(launch_one "$preset")")
    sleep 2
  done
  log "waiting pids: ${PIDS[*]}"
  FAIL=0
  for pid in "${PIDS[@]}"; do
    wait "$pid" || FAIL=1
  done
  kill "$mon_pid" 2>/dev/null || true
  write_status "done"
  [[ "$FAIL" -eq 0 ]] || { log "WARN: see $LOGDIR"; exit 1; }
  log "=== all presets done ==="
  bash "$ROOT/scripts/show_ft_val565_fusion_parallel_progress.sh"
}

case "${1:-all}" in
  bg)
    nohup bash "$0" all >> "$LOGDIR/nohup.log" 2>&1 &
    echo "[ft_fusion_par] pid=$! log=$LOGDIR/nohup.log status=$STATUS"
    sleep 2
    bash "$ROOT/scripts/show_ft_val565_fusion_parallel_progress.sh"
    ;;
  all) run_all ;;
  status) bash "$ROOT/scripts/show_ft_val565_fusion_parallel_progress.sh" ;;
  *)
    echo "Usage: $0 {bg|all|status}" >&2
    exit 1
    ;;
esac
