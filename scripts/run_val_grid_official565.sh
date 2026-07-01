#!/usr/bin/env bash
# Official val565 grid: infer + GC chamfer_distance eval + gate (Enhancement Only).
# Run in background:
#   nohup ./scripts/run_val_grid_official565.sh >> output/val_grid_official565/run.log 2>&1 &
# Watch progress:
#   ./scripts/watch_val_grid_official565.sh
set -euo pipefail

GC2026_ROOT="/root/autodl-tmp/GC2026"
source "${GC2026_ROOT}/scripts/env_setup.sh"

PROC="${GC2026_ROOT}/data/processed"
VAL_CG="${PROC}/val_cg_only_official_cgv2.txt"
VAL_PAIRS="${PROC}/val_pairs_official_cgv2.txt"
GRID_ROOT="${GC2026_ROOT}/output/val_grid_official565"
CKPT_DIR="${GC2026_ROOT}/models/superpc_pretrained"
EVAL_NAME="evaluation_gc_baseline_val565.json"
EVAL_WORKERS="${EVAL_WORKERS:-8}"
PROGRESS_JSON="${GRID_ROOT}/progress.json"
BASELINE_CACHE="${GC2026_ROOT}/output/baselines/val565_cg_gc_baseline.json"

mkdir -p "$GRID_ROOT" "${GC2026_ROOT}/output/baselines"

log() {
  echo "[$(date -Iseconds)] $*"
}

write_progress() {
  local phase="$1" experiment="$2" idx="$3" total="$4" extra="${5:-}"
  python3.12 - <<PY
import json, os
from datetime import datetime, timezone
p = "${PROGRESS_JSON}"
data = {
    "updated_at": datetime.now(timezone.utc).isoformat(),
    "phase": "${phase}",
    "current_experiment": "${experiment}",
    "experiment_index": int("${idx}"),
    "experiment_total": int("${total}"),
    "grid_root": "${GRID_ROOT}",
    "val_frames": 564,
    "metric": "chamfer_distance",
    "note": "${extra}",
}
os.makedirs(os.path.dirname(p), exist_ok=True)
with open(p, "w") as f:
    json.dump(data, f, indent=2)
PY
}

if [[ ! -s "$VAL_CG" ]]; then
  log "ERROR: missing $VAL_CG"
  exit 1
fi

# One-time aligned CG baseline on val565 (shared across experiments)
if [[ ! -f "$BASELINE_CACHE" ]]; then
  log "Computing aligned CG baseline on official val565..."
  write_progress "cg_baseline" "" 0 0 "scoring CG vs HE"
  python3.12 "${GC2026_ROOT}/scripts/evaluate_gc_baseline_metrics.py" \
    --pairs-file "$VAL_PAIRS" \
    --test-mode cg \
    --workers "$EVAL_WORKERS" \
    --out-json "$BASELINE_CACHE"
  log "CG baseline written: $BASELINE_CACHE"
fi

CG_CHAMFER=$(python3.12 -c "
import json
d=json.load(open('${BASELINE_CACHE}'))
print(d['summary'].get('mean_cg_chamfer_distance') or d['summary']['means']['chamfer_distance'])
")
log "Official val565 CG chamfer_distance baseline: ${CG_CHAMFER} mm"

infer_dual() {
  local cg_list="$1" ckpt_path="$2" out="$3" num_in="$4" num_out="$5"
  local mode="$6" voxel="$7" vision="$8"
  local shard_dir="${out}/.shards" log_dir="${out}/.logs"
  mkdir -p "$shard_dir" "$log_dir" "$out"

  python "${GC2026_ROOT}/scripts/split_pending_cg_list.py" \
    --cg-list "$cg_list" --out-dir "$out" --shard-dir "$shard_dir" --num-shards 2

  for gpu in 0 1; do
    local list="${shard_dir}/pending_${gpu}.txt"
    local n
    n=$(wc -l < "$list" | tr -d ' ')
    [[ "$n" -eq 0 ]] && continue
    CUDA_VISIBLE_DEVICES="$gpu" python "${GC2026_ROOT}/scripts/run_superpc_infer.py" \
      --cg-list "$list" --ckpt-path "$ckpt_path" --out-dir "$out" \
      --num-points "$num_in" --target-num-points "$num_out" \
      --output-mode "$mode" --blend-voxel-mm "$voxel" --skip-existing \
      > "${log_dir}/gpu${gpu}.log" 2>&1 &
    log "  infer GPU${gpu} PID=$! frames=${n}"
  done
  wait
}

eval_experiment() {
  local out="$1"
  local ev="${out}/${EVAL_NAME}"
  [[ -f "$ev" ]] && return 0
  log "  GC metric eval (workers=${EVAL_WORKERS})..."
  OMP_NUM_THREADS=2 python3.12 "${GC2026_ROOT}/scripts/evaluate_gc_baseline_metrics.py" \
    --pairs-file "$VAL_PAIRS" \
    --test-root "$out" \
    --test-mode enh \
    --also-cg \
    --workers "$EVAL_WORKERS" \
    --out-json "$ev"
  python3.12 "${GC2026_ROOT}/scripts/summarize_gc_baseline_by_sequence.py" \
    --eval-json "$ev" \
    --out-json "${out}/per_sequence_val565.json"
}

run_one() {
  local ckpt_name="$1" ckpt_path="$2" num_in="$3" num_out="$4"
  local mode="$5" voxel="$6" vision="$7"
  local tag="${ckpt_name}_${mode}_v${vision}_vx${voxel}"
  local out="${GRID_ROOT}/${tag}"
  local ev="${out}/${EVAL_NAME}"

  if [[ -f "$ev" ]]; then
    log "SKIP existing $tag"
    return 0
  fi

  log "RUN $tag"
  local n_ply=0
  if [[ -d "$out" ]]; then
    n_ply=$(find "$out" -name '*.ply' 2>/dev/null | wc -l | tr -d ' ')
  fi
  if [[ "$n_ply" -gt 0 ]]; then
    log "  RESUME: keep ${n_ply} existing PLY (--skip-existing infer)"
  else
    rm -rf "$out"
  fi
  infer_dual "$VAL_CG" "$ckpt_path" "$out" "$num_in" "$num_out" "$mode" "$voxel" "$vision"
  eval_experiment "$out"
  python3.12 "${GC2026_ROOT}/scripts/build_val_grid_summary.py" --grid-root "$GRID_ROOT"
}

# Build experiment list: checkpoint mode voxel
EXPERIMENTS=()
for ckpt in kitti360_com.pth tartanair_com.pth; do
  path="${CKPT_DIR}/${ckpt}"
  [[ -f "$path" ]] || continue
  base="${ckpt%.pth}"
  for mode in blend_cg; do
    for vx in 0.6 0.8 1.0; do
      EXPERIMENTS+=("${base}|${path}|11520|46080|${mode}|${vx}|0")
    done
  done
  # filter_cg: often better accuracy/chamfer on noisy frames
  EXPERIMENTS+=("${base}|${path}|11520|46080|filter_cg|0|0")
done

TOTAL=${#EXPERIMENTS[@]}
log "Grid experiments: ${TOTAL} (official val565, metric=chamfer_distance)"
write_progress "grid" "" 0 "$TOTAL" "starting"

idx=0
for spec in "${EXPERIMENTS[@]}"; do
  idx=$((idx + 1))
  IFS='|' read -r base path ni no mode vx vision <<< "$spec"
  tag="${base}_${mode}_v${vision}_vx${vx}"
  write_progress "grid" "$tag" "$idx" "$TOTAL" "infer+eval"
  run_one "$base" "$path" "$ni" "$no" "$mode" "$vx" "$vision"
  python3.12 "${GC2026_ROOT}/scripts/build_val_grid_summary.py" --grid-root "$GRID_ROOT"
done

write_progress "gate" "" "$TOTAL" "$TOTAL" "selecting winner"
python3.12 "${GC2026_ROOT}/scripts/val_gate.py" \
  --grid-root "$GRID_ROOT" \
  --margin 0.0 \
  --min-seq-positive 2 \
  --out-json "${GRID_ROOT}/gate_decision.json"

# Keep legacy path for submission scripts
cp -f "${GRID_ROOT}/gate_decision.json" "${GC2026_ROOT}/output/val_grid/gate_decision.json"

  python3.12 "${GC2026_ROOT}/scripts/build_per_sequence_enh_config.py" \
    --grid-root "$GRID_ROOT" 2>/dev/null || true

write_progress "done" "" "$TOTAL" "$TOTAL" "complete"
log "DONE — gate: ${GRID_ROOT}/gate_decision.json"
log "Top configs: ${GRID_ROOT}/summary_official565.csv"
