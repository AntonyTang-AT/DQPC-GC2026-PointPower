#!/usr/bin/env bash
# Rerun failed side tasks: geometry oracle + snap_fill remaining eval.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TMPDIR="${TMPDIR:-/root/autodl-tmp/tmp}"
mkdir -p "$TMPDIR"

source /root/miniconda3/etc/profile.d/conda.sh
conda activate superpc
export PYTHONPATH="$ROOT/scripts:${PYTHONPATH:-}"
export OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1

log() { echo "[fix_rerun] $(date +%H:%M:%S) $*"; }

# 1) geometry oracle (failed on /tmp full)
if [[ ! -f "$ROOT/output/enh_refine_p0_p1_p2/geometry_oracle_light_vs_heavy.json" ]]; then
  log "start geometry oracle"
  python "$ROOT/scripts/analyze_geometry_oracle.py" \
    --workers 4 \
    --out-json "$ROOT/output/enh_refine_p0_p1_p2/geometry_oracle_light_vs_heavy.json" \
    >> "$ROOT/output/enh_refine_p0_p1_p2/oracle.log" 2>&1 &
  echo $! > "$ROOT/output/enh_refine_p0_p1_p2/oracle.pid"
else
  log "oracle already done"
fi

# 2) snap_fill grid: remaining 2 evals (infer already done)
SF="$ROOT/output/enh_refine_snap_fill_grid"
need_sf=0
for p in pdlts_light_snap1.2_fill0.6 pdlts_light_snap1_adapt; do
  [[ -f "$SF/$p/evaluation_gc_baseline_val565.json" ]] || need_sf=1
done
if [[ "$need_sf" == "1" ]]; then
  log "snap_fill remaining eval (serial)"
  SKIP_INFER=1 PARALLEL_EVAL=1 EVAL_WORKERS=12 \
    bash "$ROOT/scripts/run_enh_refine_snap_fill_grid.sh" \
    >> "$SF/snap_fill_rerun.log" 2>&1 &
  echo $! > "$SF/rerun.pid"
else
  log "snap_fill eval complete"
fi

log "side tasks launched"
