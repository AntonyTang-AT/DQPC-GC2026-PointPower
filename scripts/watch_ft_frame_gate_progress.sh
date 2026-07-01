#!/usr/bin/env bash
# Live progress bar for holefill_adaptive_frame_gate val565 run.
# Usage:
#   bash scripts/watch_ft_frame_gate_progress.sh          # print once
#   bash scripts/watch_ft_frame_gate_progress.sh --watch  # refresh every 5s
#   bash scripts/watch_ft_frame_gate_progress.sh --watch 3
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT_DIR:-$ROOT/output/ft_val565_fusion/holefill_adaptive_frame_gate}"
LOGDIR="${LOGDIR:-$ROOT/output/ft_val565_fusion/logs_frame_gate}"
FT_EV="$ROOT/output/pdlts_finetune_uvg/val565_refine/pdlts_light_snap1_fill0.6_density/evaluation_gc_baseline_val565.json"
LITE_EV="$ROOT/output/ft_val565_fusion/holefill_lite_fill0.25_max10pct_adaptive_post25/evaluation_gc_baseline_val565.json"
FINAL_EV="$OUT/evaluation_gc_baseline_val565.json"
PARTIAL_EV="$OUT/evaluation_partial_val565.json"
STATE="$LOGDIR/progress.state"
TOTAL=565
EVAL_TOTAL=564

WATCH=0
INTERVAL=5
if [[ "${1:-}" == "--watch" ]]; then
  WATCH=1
  INTERVAL="${2:-5}"
fi

bar() {
  local done=$1 total=$2 width=${3:-40}
  local pct=0
  if [[ "$total" -gt 0 ]]; then pct=$((done * 100 / total)); fi
  local filled=$((done * width / (total > 0 ? total : 1)))
  local empty=$((width - filled))
  printf '['
  printf '%0.s█' $(seq 1 "$filled" 2>/dev/null) || true
  printf '%0.s░' $(seq 1 "$empty" 2>/dev/null) || true
  printf '] %3d%%  %d/%d' "$pct" "$done" "$total"
}

eta_str() {
  local remain_sec=$1
  if [[ "$remain_sec" -le 0 ]]; then echo "即将完成"; return; fi
  local m=$((remain_sec / 60)) s=$((remain_sec % 60))
  if [[ "$m" -ge 60 ]]; then
    printf '约 %dh%02dm' $((m / 60)) $((m % 60))
  else
    printf '约 %dm%02ds' "$m" "$s"
  fi
}

render_once() {
  local ply infer_pids eval_pids merge_pid
  ply=$(find "$OUT" -name '*.ply' 2>/dev/null | wc -l)
  infer_pids=$(pgrep -fc "run_enh_refine_infer.py.*holefill_adaptive_frame_gate" 2>/dev/null | head -1 || echo 0)
  eval_pids=$(pgrep -fc "evaluate_gc_baseline_metrics.py.*holefill_adaptive_frame_gate" 2>/dev/null | head -1 || echo 0)
  infer_pids=${infer_pids//[^0-9]/}; infer_pids=${infer_pids:-0}
  eval_pids=${eval_pids//[^0-9]/}; eval_pids=${eval_pids:-0}
  merge_pid=$(pgrep -f "run_enh_refine_infer.py.*val_cg_only_official_cgv2" 2>/dev/null | head -1 || true)

  local phase="done" phase_note=""
  local infer_done=$ply eval_done=0
  local eta_sec=0

  if [[ -f "$FINAL_EV" ]]; then
    phase="done"
    eval_done=$EVAL_TOTAL
    infer_done=$TOTAL
  elif [[ "$eval_pids" -gt 0 ]]; then
    phase="eval"
    phase_note="gc_baseline 评估中 (${eval_pids} workers)"
    eval_done=0
    if [[ -f "$LOGDIR/eval.log" ]]; then
      eval_done=$(python3 - <<PY 2>/dev/null || echo 0
import re
from pathlib import Path
text = Path("$LOGDIR/eval.log").read_text(errors="ignore")
m = list(re.finditer(r"gc_metrics:\s+\d+%\|[^|]*\|\s*(\d+)/(\d+)", text))
print(m[-1].group(1) if m else 0)
PY
)
    fi
    if [[ -f "$PARTIAL_EV" ]] && [[ "${eval_done:-0}" -eq 0 ]]; then
      eval_done=$(python3 -c "import json;print(json.load(open('$PARTIAL_EV')).get('summary',{}).get('num_evaluated',0))" 2>/dev/null || echo 0)
    fi
    eval_done=${eval_done//[^0-9]/}; eval_done=${eval_done:-0}
    local workers=$((eval_pids > 0 ? eval_pids : 16))
    local remain=$((EVAL_TOTAL - eval_done))
    [[ "$remain" -lt 0 ]] && remain=0
    eta_sec=$(( remain * 4 / (workers > 0 ? workers / 2 + 1 : 8) ))
  elif [[ -n "$merge_pid" ]] && [[ "$ply" -ge "$TOTAL" ]]; then
    phase="merge"
    phase_note="合并 infer_meta（跳过已有 PLY）"
    infer_done=$ply
    eta_sec=120
  elif [[ "$infer_pids" -gt 0 ]] || [[ "$ply" -lt "$TOTAL" ]]; then
    phase="infer"
    phase_note="帧级 refine 推理 (${infer_pids} shards)"
    if [[ -f "$LOGDIR/orchestrator.start" ]]; then
      local elapsed=$(( $(date +%s) - $(stat -c %Y "$LOGDIR/orchestrator.start" 2>/dev/null || date +%s) ))
      [[ "$ply" -gt 0 && "$elapsed" -gt 0 ]] && eta_sec=$(( elapsed * (TOTAL - ply) / ply ))
    fi
    [[ "$eta_sec" -eq 0 && "$ply" -lt "$TOTAL" ]] && eta_sec=$(( (TOTAL - ply) * 12 ))
  else
    phase="waiting"
    phase_note="等待启动或检查日志 $LOGDIR"
  fi

  clear 2>/dev/null || true
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║  frame_gate val565  $(date '+%Y-%m-%d %H:%M:%S')              ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo
  echo "阶段: $phase — $phase_note"
  echo
  echo "① 推理 PLY"
  bar "$infer_done" "$TOTAL"
  echo
  echo
  echo "② gc_baseline 评估"
  if [[ "$phase" == "done" ]]; then
    bar "$EVAL_TOTAL" "$EVAL_TOTAL"
  else
    bar "${eval_done:-0}" "$EVAL_TOTAL"
  fi
  echo
  if [[ "$phase" != "done" && "$eta_sec" -gt 0 ]]; then
    echo "预计剩余: $(eta_str "$eta_sec")"
  fi
  echo

  # gate tiers from infer_meta
  if [[ -f "$OUT/infer_meta.json" ]]; then
    python3 - <<PY 2>/dev/null || true
import json
from collections import Counter
d=json.load(open("$OUT/infer_meta.json"))
rec=d.get("records",[])
c=Counter(r.get("frame_fill_gate") for r in rec if r.get("frame_fill_gate"))
if c:
    print("gate 分布:", dict(c), f"(meta {len(rec)} 帧)")
PY
  fi

  # metrics if available
  python3 - <<PY 2>/dev/null || true
import json, os

def cd(path):
    d=json.load(open(path)); s=d.get("summary",d)
    return s["means"]["chamfer_distance"], s.get("num_evaluated",0)

ev=None
for p in ["$FINAL_EV", "$PARTIAL_EV"]:
    if os.path.isfile(p): ev=p; break
if ev:
    v,n=cd(ev)
    print(f"frame_gate CD: {v:.4f} mm  (n={n})")
    for label,p in [("ft density","$FT_EV"),("holefill lite","$LITE_EV")]:
        if os.path.isfile(p):
            b,_=cd(p)
            print(f"  vs {label}: {v-b:+.4f} mm")
else:
    print("指标: 评估完成后显示")
PY

  echo
  if [[ "$phase" == "done" ]]; then
    echo "✓ 全部完成 → $FINAL_EV"
  else
    echo "查看: bash scripts/watch_ft_frame_gate_progress.sh --watch"
    echo "日志: tail -f $LOGDIR/orchestrator.log"
  fi

  {
    echo "ts=$(date -Is)"
    echo "phase=$phase"
    echo "ply=$ply"
    echo "eval_done=$eval_done"
    echo "eta_sec=$eta_sec"
  } > "$STATE"
}

if [[ "$WATCH" -eq 1 ]]; then
  while true; do
    render_once
    [[ -f "$FINAL_EV" ]] && break
    sleep "$INTERVAL"
  done
else
  render_once
fi
