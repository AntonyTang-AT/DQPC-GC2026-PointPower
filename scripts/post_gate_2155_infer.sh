#!/usr/bin/env bash
# If gate selected non-vx3.0 config, start 2155 full SuperPC re-infer (post-7am stretch).
set -euo pipefail

GC2026_ROOT="/root/autodl-tmp/GC2026"
GATE_JSON="${GC2026_ROOT}/output/val_grid/gate_decision.json"
LOG="${GC2026_ROOT}/output/post_gate_2155_infer.log"

source "${GC2026_ROOT}/scripts/env_setup.sh"

if [[ ! -f "$GATE_JSON" ]]; then
  echo "Missing gate_decision.json"
  exit 1
fi

read -r WINNER VOXEL MODE FILL SNAP ADAPTIVE <<< "$(python3.12 -c "
import json
d=json.load(open('${GATE_JSON}'))
w=d.get('best_experiment') or d.get('selected_experiment','')
p=d.get('best_config', d.get('selected_params',{}))
v=p.get('blend_voxel_mm', p.get('voxel', 1.0))
m=p.get('output_mode','blend_cg')
f=p.get('fill_radius_mm', 1.0)
snap=0
if 'snap1.0' in w: snap=1.0
elif 'snap1.5' in w or 'snap' in w: snap=1.5
adapt=1 if 'adaptive' in w else 0
print(w, v, m, f, snap, adapt)
")"

echo "[$(date -Iseconds)] winner=$WINNER voxel=$VOXEL mode=$MODE fill=$FILL" | tee -a "$LOG"

INFER_EXTRA=(--output-mode "$MODE")
if [[ "$MODE" == "fill_cg" ]]; then
  INFER_EXTRA+=(--fill-radius-mm "$FILL")
else
  INFER_EXTRA+=(--blend-voxel-mm "$VOXEL")
fi
if [[ "$ADAPTIVE" == "1" ]]; then
  INFER_EXTRA+=(--adaptive-blend)
fi
if [[ "$SNAP" != "0" ]]; then
  INFER_EXTRA+=(--snap-to-cg-mm "$SNAP")
fi

# Skip 2155 only if gate still matches legacy vx3.0 submission (deprecated default)
if [[ "$WINNER" == *"vx3.0"* ]] && [[ "$MODE" == "blend_cg" ]] && [[ "$ADAPTIVE" != "1" ]] && [[ "$SNAP" == "0" ]]; then
  echo "[$(date -Iseconds)] gate still vx3.0 blend_cg — skip 2155 re-infer" | tee -a "$LOG"
  echo "Update gate_decision.json in manifest only."
  exit 0
fi

CKPT="${GC2026_ROOT}/models/superpc_pretrained/kitti360_com.pth"
ALL_CG="${GC2026_ROOT}/data/processed/all_cg_only_cgv2.txt"
OUT="${GC2026_ROOT}/output/submission_candidate"

echo "[$(date -Iseconds)] Starting 2155 re-infer with gate params..." | tee -a "$LOG"

python "${GC2026_ROOT}/scripts/split_pending_cg_list.py" \
  --cg-list "$ALL_CG" --out-dir "$OUT" \
  --shard-dir "${OUT}/.shards_gate" --num-shards 2

for gpu in 0 1; do
  list="${OUT}/.shards_gate/pending_${gpu}.txt"
  n=$(wc -l < "$list" | tr -d ' ')
  [[ "$n" -eq 0 ]] && continue
  CUDA_VISIBLE_DEVICES="$gpu" python "${GC2026_ROOT}/scripts/run_superpc_infer.py" \
    --cg-list "$list" --ckpt-path "$CKPT" --out-dir "$OUT" \
    --num-points 11520 --target-num-points 46080 \
    "${INFER_EXTRA[@]}" --skip-existing \
    >> "$LOG" 2>&1 &
  echo "GPU${gpu} PID=$! frames=$n" | tee -a "$LOG"
done
wait

OUT_DIR="$OUT" bash "${GC2026_ROOT}/scripts/post_submission_candidate.sh" >> "$LOG" 2>&1 || true
bash "${GC2026_ROOT}/scripts/build_submission_packages.sh" >> "$LOG" 2>&1 || true
echo "[$(date -Iseconds)] 2155 re-infer DONE" | tee -a "$LOG"
