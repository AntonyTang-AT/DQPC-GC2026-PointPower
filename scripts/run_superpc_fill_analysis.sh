#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/output/ft_val565_fusion/superpc_fill_analysis"
mkdir -p "$OUT"
LOG="$OUT/run.log"

pkill -f "analyze_superpc_when_helps.py" 2>/dev/null || true
pkill -f "analyze_superpc_fill_frames.py" 2>/dev/null || true
sleep 1

source /root/miniconda3/etc/profile.d/conda.sh
conda activate superpc
export PYTHONPATH="$ROOT/scripts:${PYTHONPATH:-}"

echo "[superpc_analysis] start $(date -Is)" | tee "$LOG"
nohup python "$ROOT/scripts/analyze_superpc_fill_frames.py" >> "$LOG" 2>&1 &
echo "[superpc_analysis] PID=$! log=$LOG"
echo "进度: bash scripts/watch_superpc_fill_analysis.sh --watch"
