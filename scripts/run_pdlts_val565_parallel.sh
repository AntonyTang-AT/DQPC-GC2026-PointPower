#!/usr/bin/env bash
# Dual-GPU parallel: PD-LTS light (GPU0) + heavy (GPU1) on full val565.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAIRS="$ROOT/data/processed/val_pairs_official_cgv2.txt"
CG_LIST="$ROOT/output/pdlts_val565/cg_list.txt"
OUT_LIGHT="$ROOT/output/pdlts_val565/light"
OUT_HEAVY="$ROOT/output/pdlts_val565/heavy"
LOG_DIR="$ROOT/output/pdlts_val565/logs"
mkdir -p "$LOG_DIR" "$OUT_LIGHT" "$OUT_HEAVY"

cut -f1 "$PAIRS" > "$CG_LIST"
N=$(wc -l < "$CG_LIST")
echo "[pdlts] val565 frames: $N"

source /root/miniconda3/etc/profile.d/conda.sh
conda activate superpc

launch() {
  local gpu=$1 model=$2 out=$3 log=$4
  echo "[pdlts] GPU$gpu $model -> $out (log: $log)"
  CUDA_VISIBLE_DEVICES=$gpu nohup python "$ROOT/scripts/run_pdlts_infer.py" \
    --cg-list "$CG_LIST" \
    --out-dir "$out" \
    --model "$model" \
    --cluster-size 50000 \
    --device cuda \
    > "$log" 2>&1 &
  echo $! > "${log}.pid"
}

launch 0 light "$OUT_LIGHT" "$LOG_DIR/light_gpu0.log"
launch 1 heavy "$OUT_HEAVY" "$LOG_DIR/heavy_gpu1.log"

cat > "$ROOT/output/pdlts_val565/RUNNING.md" <<EOF
# PD-LTS val565 parallel run

Started: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
Frames: $N

| Job | GPU | Model | Output | Log |
|-----|-----|-------|--------|-----|
| light | 0 | Denoiseflow-light-FBM | \`$OUT_LIGHT\` | \`$LOG_DIR/light_gpu0.log\` |
| heavy | 1 | Denoiseflow-heavy-FBM | \`$OUT_HEAVY\` | \`$LOG_DIR/heavy_gpu1.log\` |

Monitor:
\`\`\`bash
tail -f $LOG_DIR/light_gpu0.log
tail -f $LOG_DIR/heavy_gpu1.log
\`\`\`

After both finish, eval:
\`\`\`bash
bash $ROOT/scripts/eval_pdlts_val565.sh
\`\`\`
EOF

echo "[pdlts] both jobs launched. See output/pdlts_val565/RUNNING.md"
