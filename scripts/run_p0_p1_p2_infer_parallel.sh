#!/usr/bin/env bash
# Parallel infer for P0/P1/P2 presets (skips done / already running).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRID="${GRID_ROOT:-$ROOT/output/enh_refine_p0_p1_p2}"
CG_LIST="$GRID/cg_list.txt"
PARALLEL="${PARALLEL_INFER:-4}"
LOG="$GRID/infer_parallel.log"
LOGDIR="$GRID/infer_logs"
PIDFILE="$GRID/infer_parallel.pid"

mkdir -p "$LOGDIR" "$GRID"
[[ -f "$CG_LIST" ]] || cut -f1 "$ROOT/data/processed/val_pairs_official_cgv2.txt" > "$CG_LIST"

source /root/miniconda3/etc/profile.d/conda.sh
conda activate superpc
export PYTHONPATH="$ROOT/scripts:${PYTHONPATH:-}"
export OPENBLAS_NUM_THREADS="${OPENBLAS_NUM_THREADS:-1}"
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-1}"

log() { echo "[infer_par] $(date +%H:%M:%S) $*" | tee -a "$LOG"; }

COMMON=(--require-geometry-cache --geometry-fallback filter_cg --use-geometry-cache)

is_running() {
  local name="$1"
  pgrep -f "run_enh_refine_infer.py.*--out-dir ${GRID}/${name} " >/dev/null 2>&1
}

is_done() {
  [[ -f "$GRID/$1/infer_meta.json" ]]
}

launch_infer() {
  local name="$1"
  shift
  if is_done "$name"; then
    log "skip done $name"
    return 0
  fi
  if is_running "$name"; then
    log "skip running $name"
    return 0
  fi
  mkdir -p "$GRID/$name"
  log "launch $name"
  python "$ROOT/scripts/run_enh_refine_infer.py" \
    --cg-list "$CG_LIST" \
    --out-dir "$GRID/$name" \
    "$@" >> "$LOGDIR/${name}.log" 2>&1 &
}

# heavy config once
python - <<PY
import json, os
from enh_refine_config import resolve_preset
cfg = resolve_preset("pdlts_heavy_snap1.0").to_dict()
cfg["fill_mm"] = 0.6
cfg["name"] = "p1_pdlts_heavy_snap1_fill0.6"
out = "$GRID/p1_pdlts_heavy_snap1_fill0.6"
os.makedirs(out, exist_ok=True)
json.dump(cfg, open(out + "/pipeline_config.json", "w"), indent=2)
PY

PERSEQ="$GRID/per_seq_config.json"
PROXY="$GRID/frame_decision/proxy_rules.json"

declare -a QUEUE=(
  "p0_perseq|pdlts_light_snap1_fill0.6|--preset pdlts_light_snap1_fill0.6 --per-seq-config $PERSEQ"
  "p0_perseq_rollback|rollback|--preset pdlts_light_snap1_fill0.6 --per-seq-config $PERSEQ --frame-proxy-json $PROXY"
  "pdlts_light_snap1_fill0.6_post25|post25|--preset pdlts_light_snap1_fill0.6_post25"
  "pdlts_light_snap1_adapt|adapt|--preset pdlts_light_snap1_adapt"
  "p1_pdlts_heavy_snap1_fill0.6|heavy|--config-json $GRID/p1_pdlts_heavy_snap1_fill0.6/pipeline_config.json --geometry-dir $ROOT/output/pdlts_val565/heavy"
  "pdlts_light_snap1_fill0.6_density|density|--preset pdlts_light_snap1_fill0.6_density"
  "pdlts_light_snap1_fill0.6_bidir|bidir|--preset pdlts_light_snap1_fill0.6_bidir"
  "pdlts_light_snap1_fill0.6_combined|combined|--preset pdlts_light_snap1_fill0.6_combined"
)

log "start parallel=$PARALLEL queue=${#QUEUE[@]}"

active=0
for entry in "${QUEUE[@]}"; do
  IFS='|' read -r name _tag args <<< "$entry"
  # shellcheck disable=SC2206
  extra=( $args )
  while (( active >= PARALLEL )); do
    if wait -n 2>/dev/null; then
      active=$((active - 1))
    else
      wait || :
      active=0
    fi
  done
  if is_done "$name" || is_running "$name"; then
    log "skip queue $name (done or external)"
    continue
  fi
  launch_infer "$name" "${COMMON[@]}" "${extra[@]}"
  active=$((active + 1))
done

wait || :
log "all infer jobs finished"

# count
done_n=0
for entry in "${QUEUE[@]}"; do
  IFS='|' read -r name _ _ <<< "$entry"
  is_done "$name" && done_n=$((done_n + 1))
done
log "infer complete $done_n / ${#QUEUE[@]}"

# kick eval if all done
if [[ "$done_n" -eq "${#QUEUE[@]}" ]]; then
  log "starting eval phase"
  bash "$ROOT/scripts/run_p0_p1_p2_eval_only.sh" >> "$GRID/eval_parallel.log" 2>&1 &
  echo $! > "$GRID/eval_parallel.pid"
fi
