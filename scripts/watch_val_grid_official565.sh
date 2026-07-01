#!/usr/bin/env bash
# Watch official val565 grid search progress.
set -euo pipefail

GC2026_ROOT="/root/autodl-tmp/GC2026"
GRID_ROOT="${GC2026_ROOT}/output/val_grid_official565"
PROGRESS="${GRID_ROOT}/progress.json"
RUN_LOG="${GRID_ROOT}/run.log"
SUMMARY="${GRID_ROOT}/summary_official565.json"

show_status() {
  echo "========== val565 grid status =========="
  if [[ -f "$PROGRESS" ]]; then
    python3.12 - <<PY
import json
p = "${PROGRESS}"
d = json.load(open(p))
print(f"Updated:     {d.get('updated_at')}")
print(f"Phase:       {d.get('phase')}")
print(f"Experiment:  {d.get('current_experiment')}")
print(f"Progress:    {d.get('experiment_index')}/{d.get('experiment_total')}")
print(f"Metric:      {d.get('metric')}")
print(f"Note:        {d.get('note')}")
PY
  else
    echo "No progress.json yet — job not started?"
  fi

  if [[ -f "$SUMMARY" ]]; then
    echo ""
    echo "--- Completed experiments (by chamfer_distance) ---"
    python3.12 - <<PY
import json
rows = json.load(open("${SUMMARY}"))
for r in rows[:8]:
    imp = r.get('improvement_cg_minus_enh')
    imp_s = f"{imp:+.3f}" if imp is not None else "n/a"
    print(f"  {r['experiment']:<40} chamfer={r['mean_enh_chamfer_distance']:.4f}  Δcg={imp_s}")
PY
  fi

  echo ""
  echo "--- Active infer logs (tail) ---"
  for f in "${GRID_ROOT}"/*/.logs/gpu0.log; do
    [[ -f "$f" ]] || continue
    exp=$(basename "$(dirname "$(dirname "$f")")")
    echo "[${exp}/gpu0] $(tail -n 1 "$f" 2>/dev/null || echo '(empty)')"
  done
  echo "========================================"
}

case "${1:-watch}" in
  once)
    show_status
    ;;
  watch)
    show_status
    echo ""
    echo "Following ${RUN_LOG} (Ctrl+C to stop)..."
    [[ -f "$RUN_LOG" ]] || touch "$RUN_LOG"
    tail -n 30 -f "$RUN_LOG"
    ;;
  summary)
    [[ -f "$SUMMARY" ]] && python3.12 -m json.tool "$SUMMARY" || echo "No summary yet"
    ;;
  *)
    echo "Usage: $0 [once|watch|summary]"
    exit 1
    ;;
esac
