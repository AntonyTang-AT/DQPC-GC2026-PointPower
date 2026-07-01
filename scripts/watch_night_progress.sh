#!/usr/bin/env bash
# Live dashboard: Enh grid + FP eval + disk + GPU
set -euo pipefail

GC2026_ROOT="/root/autodl-tmp/GC2026"
GRID_ROOT="${GC2026_ROOT}/output/val_grid_official565"
PROGRESS="${GRID_ROOT}/progress.json"
FP_LOG="${GC2026_ROOT}/output/full_pipeline_gc_baseline_eval.log"
GRID_LOG="${GRID_ROOT}/run.log"

show() {
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║  GC2026 夜间任务进度  $(date '+%Y-%m-%d %H:%M:%S')              ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo ""

  df -h /root/autodl-tmp | awk 'NR==1 || /autodl-tmp|md0/{print "  磁盘:", $0}'
  echo ""

  if command -v nvidia-smi >/dev/null 2>&1; then
    echo "  GPU: $(nvidia-smi --query-gpu=index,utilization.gpu,memory.used --format=csv,noheader 2>/dev/null | tr '\n' ' ')"
    echo ""
  fi

  echo "── Enh val565 fast grid (5 组) ──"
  if [[ -f "$PROGRESS" ]]; then
    python3.12 - <<PY
import json
d=json.load(open("${PROGRESS}"))
print(f"  阶段:     {d.get('phase')}  ({d.get('experiment_index')}/{d.get('experiment_total')})")
print(f"  当前实验: {d.get('current_experiment')}")
print(f"  模式:     {d.get('grid_mode','')}")
print(f"  更新:     {d.get('updated_at')}")
PY
  else
    echo "  (progress.json 未生成)"
  fi

  n_ev=$(find "$GRID_ROOT" -name 'evaluation_gc_baseline_val565.json' 2>/dev/null | wc -l)
  echo "  已完成 eval: ${n_ev} 组"
  if [[ -f "${GRID_ROOT}/chamfer_tuned.done" ]]; then
    echo "  chamfer tuned: ✅ 完成"
  elif pgrep -f 'run_val_grid_chamfer_tuned' >/dev/null 2>&1; then
    echo "  chamfer tuned: ⏳ 进行中"
    if [[ -f "${GRID_ROOT}/chamfer_run.log" ]]; then
      echo "  chamfer: $(tail -1 "${GRID_ROOT}/chamfer_run.log" | tr '\r' '\n' | tail -1)"
    fi
  else
    echo "  chamfer tuned: ⏸ 待 fast grid 完成后启动"
  fi
  if [[ -f "${GRID_ROOT}/summary_official565.json" ]]; then
    python3.12 - <<PY
import json
rows=json.load(open("${GRID_ROOT}/summary_official565.json"))
print("  当前排名 (chamfer mm):")
for i,r in enumerate(rows[:5],1):
    print(f"    {i}. {r['experiment']:<42} {r['mean_enh_chamfer_distance']:.4f}")
PY
  fi

  if [[ -f "$GRID_LOG" ]]; then
    echo "  grid eval: $(tail -1 "$GRID_LOG" | tr '\r' '\n' | tail -1)"
  fi

  grid_run=$(pgrep -cf 'run_val_grid_official565_fast' || echo 0)
  echo "  grid 进程: ${grid_run}"
  echo ""

  echo "── Full Pipeline val565 eval (并行) ──"
  fp_run=$(pgrep -cf 'evaluate_full_pipeline_gc' || echo 0)
  echo "  FP 进程: ${fp_run}"
  if [[ -f "$FP_LOG" ]]; then
    echo "  fp eval: $(tail -1 "$FP_LOG" | tr '\r' '\n' | tail -1)"
  fi
  if [[ -f "${GC2026_ROOT}/output/full_pipeline_n0_v2_candidate/evaluation_gc_baseline_fp_val565_vs_baseline.json" ]]; then
    echo "  FP vs baseline: ✅ 已完成"
  else
    echo "  FP vs baseline: ⏳ 进行中"
  fi
  echo ""

  echo "── 交付物 ──"
  for f in \
    "${GRID_ROOT}/gate_decision.json" \
    "${GRID_ROOT}/MORNING_REPORT.md" \
    "${GRID_ROOT}/NEXT_STEPS.md" \
    "${GRID_ROOT}/winner_vs_baseline.json"; do
    if [[ -f "$f" ]]; then
      echo "  ✅ $(basename "$f")"
    else
      echo "  ⏳ $(basename "$f")"
    fi
  done

  if [[ -f "${GRID_ROOT}/autopilot.log" ]]; then
    echo ""
    echo "── autopilot 最新 ──"
    tail -3 "${GRID_ROOT}/autopilot.log" | sed 's/^/  /'
  fi
  echo ""
  echo "刷新: watch -n 30 $0 once  |  grid: tail -f ${GRID_LOG}  |  chamfer: tail -f ${GRID_ROOT}/chamfer_run.log"
}

case "${1:-once}" in
  once) show ;;
  watch)
    show
    echo "跟踪 grid 日志 (Ctrl+C 退出)..."
    tail -n 20 -f "$GRID_LOG" 2>/dev/null || tail -f /dev/null
    ;;
  loop)
    while true; do
      clear
      show
      sleep "${2:-30}"
    done
    ;;
  *)
    echo "Usage: $0 [once|watch|loop [sec]]"
    exit 1
    ;;
esac
