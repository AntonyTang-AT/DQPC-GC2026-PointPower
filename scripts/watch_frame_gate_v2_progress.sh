#!/usr/bin/env bash
# Progress bar for frame_gate_v2 val565 run.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT_DIR:-$ROOT/output/ft_val565_fusion/holefill_adaptive_frame_gate_v2}"
LOGDIR="${LOGDIR:-$ROOT/output/ft_val565_fusion/logs_frame_gate_v2}"
PROG="$LOGDIR/progress.json"
FINAL_EV="$OUT/evaluation_gc_baseline_val565.json"
FT_EV="$ROOT/output/pdlts_finetune_uvg/val565_refine/pdlts_light_snap1_fill0.6_density/evaluation_gc_baseline_val565.json"
TOTAL=565
EVAL_TOTAL=564
WATCH=0; INTERVAL=5
[[ "${1:-}" == "--watch" ]] && WATCH=1 && INTERVAL="${2:-5}"

bar() {
  local done=$1 total=$2 width=40 pct=0
  [[ "$total" -gt 0 ]] && pct=$((done * 100 / total))
  local filled=$((done * width / (total > 0 ? total : 1)))
  local empty=$((width - filled))
  printf '['; printf '%0.s█' $(seq 1 "$filled" 2>/dev/null) || true
  printf '%0.s░' $(seq 1 "$empty" 2>/dev/null) || true
  printf '] %3d%%  %d/%d' "$pct" "$done" "$total"
}

render() {
  local ply=0 phase=waiting eval_done=0
  ply=$(find "$OUT" -name '*.ply' 2>/dev/null | wc -l)
  local infer_p=0 eval_p=0
  infer_p=$(pgrep -fc "run_enh_refine_infer.py.*holefill_adaptive_frame_gate_v2" 2>/dev/null | head -1 || echo 0)
  eval_p=$(pgrep -fc "evaluate_gc_baseline.*holefill_adaptive_frame_gate_v2" 2>/dev/null | head -1 || echo 0)
  infer_p=${infer_p//[^0-9]/}; infer_p=${infer_p:-0}
  eval_p=${eval_p//[^0-9]/}; eval_p=${eval_p:-0}

  if [[ -f "$FINAL_EV" ]]; then
    phase=done; ply=$TOTAL; eval_done=$EVAL_TOTAL
  elif [[ "$eval_p" -gt 0 ]]; then
    phase=eval
    if [[ -f "$LOGDIR/eval.log" ]]; then
      eval_done=$(python3 -c "import re;from pathlib import Path;t=Path('$LOGDIR/eval.log').read_text(errors='ignore');m=list(re.finditer(r'(\d+)/564',t));print(m[-1].group(1) if m else 0)" 2>/dev/null || echo 0)
    fi
    eval_done=${eval_done//[^0-9]/}; eval_done=${eval_done:-0}
  elif [[ "$infer_p" -gt 0 || "$ply" -lt "$TOTAL" ]]; then
    phase=infer
  fi

  clear 2>/dev/null || true
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║  frame_gate_v2 (ft density + SuperPC gate)  $(date +%H:%M:%S)  ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo "preset: holefill_adaptive_frame_gate_v2"
  echo "阶段: $phase"
  echo
  echo "① 推理 PLY"; bar "$ply" "$TOTAL"; echo; echo
  echo "② gc_baseline 评估"; bar "${eval_done:-0}" "$EVAL_TOTAL"; echo; echo

  if [[ -f "$FINAL_EV" && -f "$FT_EV" ]]; then
    python3 - <<PY
import json
f=json.load(open("$FINAL_EV"))['summary']['means']['chamfer_distance']
t=json.load(open("$FT_EV"))['summary']['means']['chamfer_distance']
print(f"结果: fusion_v2={f:.4f} mm  ft={t:.4f} mm  Δ={f-t:+.4f} mm")
PY
  fi
  echo
  echo "bash scripts/watch_frame_gate_v2_progress.sh --watch"
}

if [[ "$WATCH" -eq 1 ]]; then
  while true; do render; [[ -f "$FINAL_EV" ]] && break; sleep "$INTERVAL"; done
  render
else
  render
fi
