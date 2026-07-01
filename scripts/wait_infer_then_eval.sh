#!/usr/bin/env bash
# Wait for all 8 infer jobs, then run parallel eval + gate.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRID="${GRID_ROOT:-$ROOT/output/enh_refine_p0_p1_p2}"
EXPS=(p0_perseq p0_perseq_rollback pdlts_light_snap1_fill0.6_post25 pdlts_light_snap1_adapt p1_pdlts_heavy_snap1_fill0.6 pdlts_light_snap1_fill0.6_density pdlts_light_snap1_fill0.6_bidir pdlts_light_snap1_fill0.6_combined)

count_done() {
  local n=0
  for e in "${EXPS[@]}"; do
    [[ -f "$GRID/$e/infer_meta.json" ]] && n=$((n + 1))
  done
  echo "$n"
}

while true; do
  d=$(count_done)
  running=$(pgrep -fc 'run_enh_refine_infer.py.*enh_refine_p0_p1_p2' || echo 0)
  echo "$(date +%H:%M:%S) infer_done=$d/8 running=$running"
  if [[ "$d" -eq 8 ]]; then
    echo "All infer done — starting eval"
    bash "$ROOT/scripts/run_p0_p1_p2_eval_only.sh" >> "$GRID/eval_parallel.log" 2>&1
    echo "Eval finished — see $GRID/gate_decision.json"
    exit 0
  fi
  if [[ "$running" -eq 0 && "$d" -lt 8 ]]; then
    echo "WARN: no infer running but only $d/8 done — check infer_logs/"
  fi
  sleep 60
done
