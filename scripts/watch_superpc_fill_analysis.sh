#!/usr/bin/env bash
# Progress bar for analyze_superpc_fill_frames.py (fusion vs ft per-frame).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROG="${PROG:-$ROOT/output/ft_val565_fusion/superpc_fill_analysis/progress.json}"
SUMMARY="${SUMMARY:-$ROOT/output/ft_val565_fusion/superpc_fill_analysis/summary.json}"
LOG="${LOG:-$ROOT/output/ft_val565_fusion/superpc_fill_analysis/run.log}"
WATCH=0
INTERVAL=3
[[ "${1:-}" == "--watch" ]] && WATCH=1 && INTERVAL="${2:-3}"

bar() {
  local done=$1 total=$2 width=40
  local pct=0
  [[ "$total" -gt 0 ]] && pct=$((done * 100 / total))
  local filled=$((done * width / (total > 0 ? total : 1)))
  local empty=$((width - filled))
  printf '['
  printf '%0.s█' $(seq 1 "$filled" 2>/dev/null) || true
  printf '%0.s░' $(seq 1 "$empty" 2>/dev/null) || true
  printf '] %3d%%  %d/%d' "$pct" "$done" "$total"
}

render() {
  local phase=waiting done=0 total=564 note="" updated=""
  if [[ -f "$PROG" ]]; then
    read -r phase done total note updated < <(python3 - <<PY
import json
p=json.load(open("$PROG"))
print(p.get("phase","?"), p.get("done",0), p.get("total",564), p.get("note","").replace(" ","_"), p.get("updated",""))
PY
)
  fi
  clear 2>/dev/null || true
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║  SuperPC 填洞收益分析（fusion vs ft）  $(date +%H:%M:%S)       ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo
  echo "模型: holefill_adaptive_frame_gate  vs  ft PD-LTS density"
  echo "阶段: $phase — ${note//_/ }"
  [[ -n "$updated" ]] && echo "更新: $updated"
  echo
  bar "$done" "$total"
  echo
  echo
  if pgrep -f "analyze_superpc_fill_frames.py" >/dev/null 2>&1; then
    echo "状态: 运行中"
  elif [[ "$phase" == "done" ]]; then
    echo "状态: ✓ 完成"
  else
    echo "状态: 未运行（bash scripts/run_superpc_fill_analysis.sh）"
  fi
  if [[ -f "$SUMMARY" ]]; then
    python3 - <<PY
import json
s=json.load(open("$SUMMARY"))
print(f"\n结果预览:")
print(f"  fusion CD: {s['fusion_cd_mean']:.4f}  ft: {s['ft_cd_mean']:.4f}  Δ: {s['delta_fusion_minus_ft']:+.4f}")
print(f"  SuperPC 有益帧: {s['fusion_wins']}/{s['n_frames']}  有害: {s['fusion_hurts']}")
for seq,v in s.get('by_sequence',{}).items():
    print(f"    {seq}: wins {v['fusion_wins']}/{v['n']}  mean Δ {v['mean_d_fusion_ft']:+.4f}")
PY
  fi
  echo
  echo "输出:"
  echo "  $ROOT/output/ft_val565_fusion/superpc_fill_analysis/per_frame_fusion_vs_ft.csv"
  echo "  $ROOT/output/ft_val565_fusion/superpc_fill_analysis/frames_superpc_helps.csv"
  echo "  tail -f $LOG"
}

if [[ "$WATCH" -eq 1 ]]; then
  while true; do
    render
    [[ -f "$PROG" ]] && grep -q '"phase": "done"' "$PROG" 2>/dev/null && break
    sleep "$INTERVAL"
  done
  render
else
  render
fi
