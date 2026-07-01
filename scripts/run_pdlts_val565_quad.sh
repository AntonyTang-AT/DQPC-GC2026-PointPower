#!/usr/bin/env bash
# PD-LTS val565 multi-GPU parallel, skip-existing resume.
#
# Modes:
#   PDLTS_TRACK=light_only  — 4× GPU all run light (default after heavy pause)
#   PDLTS_TRACK=dual        — GPU0/1 light, GPU2/3 heavy (legacy)
#
# Examples:
#   PDLTS_TRACK=light_only bash scripts/run_pdlts_val565_quad.sh
#   RESUME=1 PDLTS_TRACK=light_only bash scripts/run_pdlts_val565_quad.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CG_LIST="${CG_LIST:-$ROOT/output/pdlts_val565/cg_list.txt}"
OUT_LIGHT="$ROOT/output/pdlts_val565/light"
OUT_HEAVY="$ROOT/output/pdlts_val565/heavy"
LOG_DIR="$ROOT/output/pdlts_val565/logs"
PDLTS_TRACK="${PDLTS_TRACK:-light_only}"
RESUME="${RESUME:-0}"
STAGGER_SEC="${STAGGER_SEC:-15}"
CLUSTER_SIZE="${CLUSTER_SIZE:-50000}"

mkdir -p "$LOG_DIR"
source /root/miniconda3/etc/profile.d/conda.sh
conda activate superpc
export OPENBLAS_NUM_THREADS=8
export OMP_NUM_THREADS=8
export MKL_NUM_THREADS=8
export PYTHONPATH="$ROOT/scripts:${PYTHONPATH:-}"
PYTHON="${CONDA_PREFIX}/bin/python"

if [[ ! -s "$CG_LIST" ]]; then
  cut -f1 "$ROOT/data/processed/val_pairs_official_cgv2.txt" > "$CG_LIST"
fi

log() { echo "[pdlts_quad] $(date +%H:%M:%S) $*"; }

stop_heavy_workers() {
  log "stopping heavy workers..."
  pkill -f "run_pdlts_infer.py.*--model heavy.*pdlts_val565" 2>/dev/null || true
}

if [[ "$PDLTS_TRACK" == "light_only" ]]; then
  stop_heavy_workers
  if [[ "$RESUME" != "1" ]]; then
    log "restarting all pdlts_val565 workers for 4-GPU light-only layout"
    pkill -f "run_pdlts_infer.py.*pdlts_val565" 2>/dev/null || true
    sleep 2
  fi
elif [[ "$RESUME" != "1" ]]; then
  pkill -f "run_pdlts_infer.py.*pdlts_val565" 2>/dev/null || true
  sleep 2
fi

log "pre-warm pytorch3d..."
"$PYTHON" -c "from pytorch3d.loss import chamfer_distance; print('pytorch3d ok')" \
  > "$LOG_DIR/prewarm_pytorch3d.log" 2>&1 || {
  log "WARN: pytorch3d prewarm failed — see $LOG_DIR/prewarm_pytorch3d.log"
}

shard_worker_running() {
  local list="$1"
  pgrep -af "run_pdlts_infer.py" 2>/dev/null | grep -F "$list" >/dev/null 2>&1
}

launch_sharded() {
  local model="$1"
  local out_dir="$2"
  shift 2
  local -a gpus=("$@")
  local num_shards=${#gpus[@]}
  local shard_dir="$out_dir/.shards_${num_shards}gpu"

  mkdir -p "$shard_dir"
  "$PYTHON" "$ROOT/scripts/split_pending_cg_list.py" \
    --cg-list "$CG_LIST" \
    --out-dir "$out_dir" \
    --shard-dir "$shard_dir" \
    --num-shards "$num_shards"

  for shard_idx in "${!gpus[@]}"; do
    local gpu="${gpus[$shard_idx]}"
    local list
    list="$(cd "$shard_dir" && pwd)/pending_${shard_idx}.txt"
    local n=0
    [[ -f "$list" ]] && n=$(wc -l < "$list" | tr -d ' ')
    if [[ "$n" -eq 0 ]]; then
      log "GPU${gpu} ${model}: nothing pending (shard ${shard_idx})"
      continue
    fi
    if [[ "$RESUME" == "1" ]] && shard_worker_running "$list"; then
      log "GPU${gpu} ${model}: shard worker already running — skip"
      continue
    fi
    local logfile="$LOG_DIR/${model}_gpu${gpu}.log"
    log "GPU${gpu} ${model}: ${n} pending (shard ${shard_idx}/${num_shards}) -> $logfile"
    (
      export CUDA_VISIBLE_DEVICES="$gpu"
      cd "$ROOT"
      exec "$PYTHON" "$ROOT/scripts/run_pdlts_infer.py" \
        --cg-list "$list" \
        --out-dir "$out_dir" \
        --model "$model" \
        --cluster-size "$CLUSTER_SIZE" \
        --device cuda
    ) >> "$logfile" 2>&1 &
    echo $! > "${logfile}.pid"
    sleep "$STAGGER_SEC"
  done
}

if [[ "$PDLTS_TRACK" == "light_only" ]]; then
  log "mode=light_only: GPUs 0,1,2,3 -> light (${CLUSTER_SIZE} cluster)"
  launch_sharded light "$OUT_LIGHT" 0 1 2 3
  layout="GPU0-3 all light (4 shards)"
elif [[ "$PDLTS_TRACK" == "dual" ]]; then
  log "mode=dual: GPU0/1 light, GPU2/3 heavy"
  launch_sharded light "$OUT_LIGHT" 0 1
  launch_sharded heavy "$OUT_HEAVY" 2 3
  layout="GPU0/1 light | GPU2/3 heavy"
else
  echo "Unknown PDLTS_TRACK=$PDLTS_TRACK (use light_only or dual)" >&2
  exit 1
fi

cat > "$ROOT/output/pdlts_val565/RUNNING_QUAD.md" <<EOF
# PD-LTS 多卡推理

Updated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
Track: **${PDLTS_TRACK}**
Layout: ${layout}
Heavy: **paused** (light_only mode)
RESUME=${RESUME}  CLUSTER_SIZE=${CLUSTER_SIZE}

Monitor:
\`\`\`bash
find $OUT_LIGHT -name '*.ply' | wc -l   # target 565
tail -f $LOG_DIR/light_gpu0.log
tail -f $LOG_DIR/light_gpu3.log
pgrep -af run_pdlts_infer
nvidia-smi
\`\`\`

Relaunch light-only 4-GPU:
\`\`\`bash
PDLTS_TRACK=light_only RESUME=0 bash $ROOT/scripts/run_pdlts_val565_quad.sh
RESUME=1 PDLTS_TRACK=light_only bash $ROOT/scripts/run_pdlts_val565_quad.sh
\`\`\`
EOF

log "workers launched track=${PDLTS_TRACK} RESUME=${RESUME}"
