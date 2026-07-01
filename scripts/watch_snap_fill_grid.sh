#!/usr/bin/env bash
# Update snap/fill grid progress snapshot.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRID="$ROOT/output/enh_refine_snap_fill_grid"
LOG="$GRID/snap_fill_grid.log"
PROGRESS="$GRID/PROGRESS.md"
PIDFILE="$GRID/grid.pid"

mode="full"
parallel=1
if [[ -f "$GRID/mode.txt" ]]; then
  mode=$(cat "$GRID/mode.txt")
  [[ "$mode" == *FAST_GRID=1* ]] && TOTAL=6 || TOTAL=25
  if [[ "$mode" =~ PARALLEL=([0-9]+) ]]; then
    parallel="${BASH_REMATCH[1]}"
  fi
else
  TOTAL=$(PYTHONPATH="$ROOT/scripts" python -c "from enh_refine_config import PHASE2D_PRESETS; print(len(PHASE2D_PRESETS))" 2>/dev/null || echo 25)
fi

infer_done=0
eval_done=0
current=""
if [[ -d "$GRID" ]]; then
  for d in "$GRID"/pdlts_light_snap*; do
    [[ -d "$d" ]] || continue
    name=$(basename "$d")
    if [[ -f "$d/infer_meta.json" ]]; then
      infer_done=$((infer_done + 1))
    fi
    if [[ -f "$d/evaluation_gc_baseline_val565.json" ]]; then
      eval_done=$((eval_done + 1))
    fi
  done
fi

if [[ -f "$LOG" ]]; then
  current=$(grep -E '^\[snap_fill_grid\].*(infer|eval) preset=' "$LOG" 2>/dev/null | tail -1 | sed 's/.*preset=//')
  tqdm_line=$(grep -oE 'refine:pdlts_light[^:]*:.*[0-9]+/565' "$LOG" 2>/dev/null | tail -1 | tr '\r' '\n' | tail -1)
else
  tqdm_line=""
fi

running="no"
if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  running="yes"
elif pgrep -f "run_enh_refine_snap_fill_grid.sh" >/dev/null 2>&1; then
  running="yes"
elif pgrep -f "output/enh_refine_snap_fill_grid" >/dev/null 2>&1; then
  running="yes"
fi

started=""
[[ -f "$GRID/started_at.txt" ]] && started=$(cat "$GRID/started_at.txt")

# ETA: ~20 min/preset infer (565 frames CPU), amortized by parallel workers
remain=$((TOTAL - infer_done))
eval_remain=$((TOTAL - eval_done))
if [[ "$infer_done" -ge "$TOTAL" && "$eval_done" -lt "$TOTAL" ]]; then
  # infer done: ETA from eval only (~10 min/preset serial, ~8 min at 16 workers)
  if [[ "${PARALLEL_EVAL:-1}" -gt 1 ]]; then
    eta_min=$(( (eval_remain * 10 + PARALLEL_EVAL - 1) / PARALLEL_EVAL ))
  else
    eta_min=$((eval_remain * 10))
  fi
elif [[ "$parallel" -gt 1 ]]; then
  eta_min=$(( (remain * 20 + parallel - 1) / parallel ))
else
  eta_min=$((remain * 20))
fi

mkdir -p "$GRID"
cat > "$PROGRESS" <<EOF
# Snap/Fill 细网格进度

Updated: $(date '+%Y-%m-%d %H:%M:%S %Z')
Started: ${started:-unknown}
Running: **${running}**
Mode: **${mode:-full}** | parallel: **${parallel:-1}**

| 阶段 | 完成 | 总计 |
|------|------|------|
| infer | ${infer_done} | ${TOTAL} |
| eval | ${eval_done} | ${TOTAL} |

**当前 preset:** \`${current:-—}\`
**当前帧进度:** \`${tqdm_line:-—}\`
**预计剩余:** ~${eta_min} min（约 $((eta_min / 60))h $((eta_min % 60))m）

## 监控命令

\`\`\`bash
tail -f $LOG
bash scripts/watch_snap_fill_grid.sh    # 每 60s 刷新本文件
cat $PROGRESS
\`\`\`

Gate 输出: \`$GRID/gate_decision.json\`
EOF

echo "$PROGRESS"
cat "$PROGRESS"
