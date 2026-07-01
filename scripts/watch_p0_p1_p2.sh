#!/usr/bin/env bash
# Quick status for parallel P0/P1/P2 pipeline.
GRID="${GRID_ROOT:-/root/autodl-tmp/GC2026/output/enh_refine_p0_p1_p2}"
EXPS=(p0_perseq p0_perseq_rollback pdlts_light_snap1_fill0.6_post25 pdlts_light_snap1_adapt p1_pdlts_heavy_snap1_fill0.6 pdlts_light_snap1_fill0.6_density pdlts_light_snap1_fill0.6_bidir pdlts_light_snap1_fill0.6_combined)
infer_done=0 eval_done=0 running=0
for e in "${EXPS[@]}"; do
  [[ -f "$GRID/$e/infer_meta.json" ]] && infer_done=$((infer_done+1))
  [[ -f "$GRID/$e/evaluation_gc_baseline_val565.json" ]] && eval_done=$((eval_done+1))
  pgrep -f "run_enh_refine_infer.py.*--out-dir $GRID/$e " >/dev/null && running=$((running+1))
done
echo "$(date '+%H:%M:%S') infer=$infer_done/8 running=$running eval=$eval_done/8"
pgrep -af 'evaluate_gc_baseline.*enh_refine_p0_p1_p2' | head -3
test -f "$GRID/gate_decision.json" && echo "GATE: $GRID/gate_decision.json"
