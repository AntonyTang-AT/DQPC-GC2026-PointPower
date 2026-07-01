#!/usr/bin/env bash
# Chamfer-tuned val565 grid: new SuperPC post-process modes (fill_cg, filter_blend, etc.)
# Runs after fast grid; shares output/val_grid_official565 with fast experiments.
#
#   EVAL_WORKERS=4 nohup ./scripts/run_val_grid_chamfer_tuned.sh \
#     >> output/val_grid_official565/chamfer_run.log 2>&1 &
set -euo pipefail

GC2026_ROOT="/root/autodl-tmp/GC2026"
source "${GC2026_ROOT}/scripts/env_setup.sh"

PROC="${GC2026_ROOT}/data/processed"
VAL_CG="${PROC}/val_cg_only_official_cgv2.txt"
VAL_PAIRS="${PROC}/val_pairs_official_cgv2.txt"
GRID_ROOT="${GC2026_ROOT}/output/val_grid_official565"
CKPT_DIR="${GC2026_ROOT}/models/superpc_pretrained"
EVAL_NAME="evaluation_gc_baseline_val565.json"
EVAL_WORKERS="${EVAL_WORKERS:-4}"
PROGRESS_JSON="${GRID_ROOT}/progress.json"
DONE_MARKER="${GRID_ROOT}/chamfer_tuned.done"

mkdir -p "$GRID_ROOT"

log() {
  echo "[$(date -Iseconds)] [chamfer] $*"
}

write_progress() {
  local phase="$1" experiment="$2" idx="$3" total="$4" extra="${5:-}"
  python3.12 - <<PY
import json, os
from datetime import datetime, timezone
p = "${PROGRESS_JSON}"
prev = {}
if os.path.isfile(p):
    with open(p) as f:
        prev = json.load(f)
data = {
    **prev,
    "updated_at": datetime.now(timezone.utc).isoformat(),
    "phase": "${phase}",
    "current_experiment": "${experiment}",
    "chamfer_experiment_index": int("${idx}"),
    "chamfer_experiment_total": int("${total}"),
    "grid_root": "${GRID_ROOT}",
    "grid_mode": "chamfer_tuned",
    "val_frames": 564,
    "metric": "chamfer_distance",
    "note": "${extra}",
}
with open(p, "w") as f:
    json.dump(data, f, indent=2)
PY
}

build_tag() {
  local base="$1" mode="$2" vision="$3" param="$4" suffix="${5:-}"
  GC2026_ROOT="${GC2026_ROOT}" python3.12 - <<PY
import os, sys
sys.path.insert(0, os.path.join("${GC2026_ROOT}", "scripts"))
from enh_experiment_tag import experiment_tag
base = "${base}"
mode = "${mode}"
vision = int("${vision}")
param = float("${param}")
suffix = "${suffix}"
if mode == "fill_cg":
    tag = experiment_tag(base, mode, vision, fill_radius=param)
else:
    tag = experiment_tag(base, mode, vision, voxel=param)
if suffix:
    tag = tag + "_" + suffix
print(tag)
PY
}

infer_dual() {
  local cg_list="$1" ckpt_path="$2" out="$3" num_in="$4" num_out="$5"
  local mode="$6" param="$7" vision="$8" extra="${9:-}"
  local shard_dir="${out}/.shards" log_dir="${out}/.logs"
  mkdir -p "$shard_dir" "$log_dir" "$out"

  local infer_args=(--output-mode "$mode")
  if [[ "$mode" == "fill_cg" ]]; then
    infer_args+=(--fill-radius-mm "$param")
  else
    infer_args+=(--blend-voxel-mm "$param")
  fi
  if [[ "$extra" == *adaptive* ]]; then
    infer_args+=(--adaptive-blend)
  fi
  if [[ "$extra" == *snap1.0* ]]; then
    infer_args+=(--snap-to-cg-mm 1.0)
  elif [[ "$extra" == *snap1.5* ]]; then
    infer_args+=(--snap-to-cg-mm 1.5)
  fi

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
      "${infer_args[@]}" --skip-existing \
      > "${log_dir}/gpu${gpu}.log" 2>&1 &
    log "  infer GPU${gpu} PID=$! frames=${n} mode=${mode} param=${param} ${extra}"
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
  local base="$1" ckpt_path="$2" num_in="$3" num_out="$4"
  local mode="$5" param="$6" vision="$7" extra="${8:-}"
  local tag
  tag=$(build_tag "$base" "$mode" "$vision" "$param" "$extra")
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
    log "  RESUME: keep ${n_ply} existing PLY"
  else
    rm -rf "$out"
  fi
  infer_dual "$VAL_CG" "$ckpt_path" "$out" "$num_in" "$num_out" "$mode" "$param" "$vision" "$extra"
  eval_experiment "$out"
  python3.12 "${GC2026_ROOT}/scripts/build_val_grid_summary.py" --grid-root "$GRID_ROOT"
}

# Chamfer-focused experiments — voxel policy: all blend vx <= 1.0 mm
# (grid showed vx1.0=19.08 << vx3.0=22.17; larger vx discarded)
EXPERIMENTS=()
KITT_PATH="${CKPT_DIR}/kitti360_com.pth"
if [[ -f "$KITT_PATH" ]]; then
  base="kitti360_com"
  # fill_cg: gap-fill radius <= 1.0 mm (parallel to fine voxel)
  for fr in 0.6 0.8 1.0; do
    EXPERIMENTS+=("${base}|${KITT_PATH}|11520|46080|fill_cg|${fr}|0|")
  done
  # filter then blend (fine voxel only)
  for vx in 0.6 0.8 1.0; do
    EXPERIMENTS+=("${base}|${KITT_PATH}|11520|46080|filter_blend_cg|${vx}|0|")
  done
  # blend then light SOR
  for vx in 0.6 0.8 1.0; do
    EXPERIMENTS+=("${base}|${KITT_PATH}|11520|46080|blend_filter_cg|${vx}|0|")
  done
  # plain blend + adaptive / snap at fine voxel
  EXPERIMENTS+=("${base}|${KITT_PATH}|11520|46080|blend_cg|0.6|0|")
  EXPERIMENTS+=("${base}|${KITT_PATH}|11520|46080|blend_cg|0.8|0|")
  EXPERIMENTS+=("${base}|${KITT_PATH}|11520|46080|blend_cg|1.0|0|")
  EXPERIMENTS+=("${base}|${KITT_PATH}|11520|46080|blend_cg|1.0|0|adaptive")
  EXPERIMENTS+=("${base}|${KITT_PATH}|11520|46080|blend_cg|0.8|0|snap1.0")
fi

TOTAL=${#EXPERIMENTS[@]}
if [[ "$TOTAL" -eq 0 ]]; then
  log "ERROR: kitti360_com.pth not found"
  exit 1
fi

log "Chamfer tuned grid: ${TOTAL} experiments on official val565"
write_progress "chamfer_grid" "" 0 "$TOTAL" "chamfer_tuned_starting"

idx=0
for spec in "${EXPERIMENTS[@]}"; do
  idx=$((idx + 1))
  IFS='|' read -r base path ni no mode param vision extra <<< "$spec"
  tag=$(build_tag "$base" "$mode" "$vision" "$param" "$extra")
  write_progress "chamfer_grid" "$tag" "$idx" "$TOTAL" "infer+eval"
  run_one "$base" "$path" "$ni" "$no" "$mode" "$param" "$vision" "$extra"
  python3.12 "${GC2026_ROOT}/scripts/build_val_grid_summary.py" --grid-root "$GRID_ROOT"
done

write_progress "chamfer_gate" "" "$TOTAL" "$TOTAL" "re-gate all experiments"
python3.12 "${GC2026_ROOT}/scripts/val_gate.py" \
  --grid-root "$GRID_ROOT" \
  --margin 0.0 \
  --min-seq-positive 2 \
  --out-json "${GRID_ROOT}/gate_decision.json"

cp -f "${GRID_ROOT}/gate_decision.json" "${GC2026_ROOT}/output/val_grid/gate_decision.json"

python3.12 "${GC2026_ROOT}/scripts/build_per_sequence_enh_config.py" \
  --grid-root "$GRID_ROOT" 2>/dev/null || true

date -Iseconds > "$DONE_MARKER"
write_progress "chamfer_done" "" "$TOTAL" "$TOTAL" "chamfer_tuned_complete"
log "DONE — re-gate: ${GRID_ROOT}/gate_decision.json"
log "Summary: ${GRID_ROOT}/summary_official565.csv"
