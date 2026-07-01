#!/usr/bin/env bash
# Run only temporal-attn hybrid (ft PD-LTS + ft density history + SuperPC).
#
#   bash scripts/run_ft_temporal_attn_only.sh bg      # resume
#   FORCE_RERUN=1 bash scripts/run_ft_temporal_attn_only.sh bg
#   bash scripts/show_ft_temporal_attn_only_progress.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRESET="temporal_attn_hybrid_pdlts_superpc_snap1_fill0.6_density"
OUT_DIR="${OUT_DIR:-$ROOT/output/ft_val565_fusion/$PRESET}"
GEOMETRY_DIR="${GEOMETRY_DIR:-$ROOT/output/pdlts_finetune_uvg/val565/light}"
ENH_HISTORY_DIR="${ENH_HISTORY_DIR:-$ROOT/output/pdlts_finetune_uvg/val565_refine/pdlts_light_snap1_fill0.6_density}"
SUPERPC="${SUPERPC_GEOM:-$ROOT/output/submission_candidate}"
LOGDIR="${LOGDIR:-$ROOT/output/ft_val565_fusion/logs/temporal_attn_only}"
STATUS="${STATUS:-$ROOT/output/ft_val565_fusion/temporal_attn_only_status.json}"
FORCE_RERUN="${FORCE_RERUN:-0}"
PRESET_JOBS=1

# shellcheck source=cpu_parallel_defaults.sh
source "$ROOT/scripts/cpu_parallel_defaults.sh"

mkdir -p "$LOGDIR"
log() { echo "[temporal_attn] $(date +%H:%M:%S) $*" | tee -a "$LOGDIR/run.log"; }

write_status() {
  python3 - "$1" "$STATUS" "$OUT_DIR" <<'PY'
import glob, json, os, sys, time
phase, status_path, out_dir = sys.argv[1:4]
n = len(glob.glob(os.path.join(out_dir, "*", "*.ply")))
ev = os.path.join(out_dir, "evaluation_gc_baseline_val565.json")
cd = None
if os.path.isfile(ev):
    d = json.load(open(ev)); s = d.get("summary", d)
    cd = (s.get("means") or {}).get("chamfer_distance") or s.get("mean_enh_chamfer_distance")
json.dump({
    "updated": time.strftime("%Y-%m-%d %H:%M:%S"),
    "phase": phase,
    "ply": n,
    "eval_done": os.path.isfile(ev),
    "chamfer_mm": cd,
    "out_dir": out_dir,
}, open(status_path, "w"), indent=2)
PY
}

run_all() {
  log "start preset=$PRESET FORCE_RERUN=$FORCE_RERUN NUM_SHARDS=$NUM_SHARDS"
  write_status "running"
  (
    while pgrep -f "run_enh_refine_infer.py.*temporal_attn_hybrid" >/dev/null 2>&1 \
      || pgrep -f "evaluate_gc_baseline.*temporal_attn_hybrid" >/dev/null 2>&1; do
      sleep 30
      write_status "running"
    done
  ) &
  local mon=$!

  FORCE_RERUN="$FORCE_RERUN" PRESET="$PRESET" OUT_DIR="$OUT_DIR" \
    GEOMETRY_DIR="$GEOMETRY_DIR" GEOMETRY_SECONDARY_DIR="$SUPERPC" \
    ENH_HISTORY_DIR="$ENH_HISTORY_DIR" NUM_SHARDS="$NUM_SHARDS" \
    EVAL_WORKERS="$EVAL_WORKERS" LOGDIR="$LOGDIR" \
    bash "$ROOT/scripts/run_ft_fusion_one.sh" >> "$LOGDIR/fusion_one.log" 2>&1

  kill "$mon" 2>/dev/null || true
  write_status "done"
  log "done"
  bash "$ROOT/scripts/show_ft_temporal_attn_only_progress.sh"
}

case "${1:-all}" in
  bg)
    nohup bash "$0" all >> "$LOGDIR/nohup.log" 2>&1 &
    echo "[temporal_attn] pid=$! log=$LOGDIR/nohup.log status=$STATUS"
    sleep 2
    bash "$ROOT/scripts/show_ft_temporal_attn_only_progress.sh"
    ;;
  all) run_all ;;
  status) bash "$ROOT/scripts/show_ft_temporal_attn_only_progress.sh" ;;
  *) echo "Usage: $0 {bg|all|status}" >&2; exit 1 ;;
esac
