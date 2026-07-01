#!/usr/bin/env bash
# Phase-2 refine pipeline: does NOT require Phase-1 PD-LTS to finish.
# 2A: CG-only presets (always full val565)
# 2B: SuperPC 565-frame cache (already complete from val grid)
# 2C: PD-LTS partial cache (optional; missing frames -> filter_cg fallback)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRID="${GRID_ROOT:-$ROOT/output/enh_refine_phase2}"
PAIRS="$ROOT/data/processed/val_pairs_official_cgv2.txt"
CG_LIST="$GRID/cg_list.txt"
PHASE="${PHASE:-all}"   # all | 2a | 2b | 2c
SKIP_INFER="${SKIP_INFER:-0}"
EVAL_WORKERS="${EVAL_WORKERS:-4}"
RAN_PRESETS=()

mkdir -p "$GRID"
cut -f1 "$PAIRS" > "$CG_LIST"

source /root/miniconda3/etc/profile.d/conda.sh
conda activate superpc
export PYTHONPATH="$ROOT/scripts:${PYTHONPATH:-}"

log() { echo "[phase2] $(date +%H:%M:%S) $*"; }

log "geometry source status:"
python - <<PY
import json
from enh_geometry_sources import source_status
print(json.dumps(source_status('$ROOT'), indent=2))
PY

run_preset() {
  local preset="$1"
  local extra="${2:-}"
  local out="$GRID/$preset"
  mkdir -p "$out"
  RAN_PRESETS+=("$preset")
  log "infer preset=$preset"
  # shellcheck disable=SC2086
  python "$ROOT/scripts/run_enh_refine_infer.py" \
    --cg-list "$CG_LIST" \
    --out-dir "$out" \
    --preset "$preset" \
    --require-geometry-cache \
    --geometry-fallback filter_cg \
    $extra
}

if [[ "$SKIP_INFER" != "1" ]]; then
  if [[ "$PHASE" == "all" || "$PHASE" == "2a" ]]; then
    log "=== Phase 2A: no external geometry ==="
    for p in cg_passthrough filter_cg; do
      RAN_PRESETS+=("$p")
      python "$ROOT/scripts/run_enh_refine_infer.py" \
        --cg-list "$CG_LIST" --out-dir "$GRID/$p" --preset "$p"
    done
  fi

  if [[ "$PHASE" == "all" || "$PHASE" == "2b" ]]; then
    log "=== Phase 2B: SuperPC filter_cg cache (565 frames) ==="
    for p in superpc_filter_snap1.0 superpc_filter_snap1_fill0.6 superpc_filter_post25; do
      run_preset "$p"
    done
  fi

  if [[ "$PHASE" == "all" || "$PHASE" == "2c" ]]; then
    log "=== Phase 2C: PD-LTS light cache ==="
    for p in pdlts_light_snap1.0 pdlts_light_snap1_fill0.6 pdlts_light_snap1_adapt; do
      run_preset "$p" "--use-geometry-cache"
    done
  fi

  if [[ "$PHASE" == "all" || "$PHASE" == "2d" ]]; then
    log "=== Phase 2D: snap/fill fine grid (delegated) ==="
    GRID_ROOT="$ROOT/output/enh_refine_snap_fill_grid" \
      bash "$ROOT/scripts/run_enh_refine_snap_fill_grid.sh"
  fi
fi

log "=== eval + gate ==="
if [[ ${#RAN_PRESETS[@]} -eq 0 ]]; then
  RAN_PRESETS=(cg_passthrough filter_cg superpc_filter_snap1.0 superpc_filter_snap1_fill0.6 superpc_filter_post25 \
    pdlts_light_snap1.0 pdlts_light_snap1_fill0.6 pdlts_heavy_snap1.0)
fi
PRESETS=("${RAN_PRESETS[@]}")

: > "$GRID/_summary_lines.jsonl"
for preset in "${PRESETS[@]}"; do
  out="$GRID/$preset"
  [[ -d "$out" ]] || continue
  python "$ROOT/scripts/evaluate_gc_baseline_metrics.py" \
    --pairs-file "$PAIRS" \
    --test-root "$out" \
    --workers "$EVAL_WORKERS" \
    --out-json "$out/evaluation_gc_baseline_val565.json" \
    --out-csv "$out/evaluation_gc_baseline_val565.csv" > /dev/null 2>&1 || true
  if [[ -f "$out/evaluation_gc_baseline_val565.json" ]]; then
    python - <<PY || true
import json
d=json.load(open('$out/evaluation_gc_baseline_val565.json'))
s=d.get('summary', d)
ch=(s.get('means') or {}).get('chamfer_distance')
if ch is None:
    ch=s.get('mean_enh_chamfer_distance')
if ch is not None:
    print(json.dumps({'experiment':'$preset','mean_enh_chamfer_distance':ch,
                      'improvement_cg_minus_enh':s.get('mean_improvement_cg_minus_enh')}))
PY
  fi
done >> "$GRID/_summary_lines.jsonl"

python - <<PY
import json
rows=[]
for line in open('$GRID/_summary_lines.jsonl'):
    line=line.strip()
    if not line: continue
    try:
        row=json.loads(line)
    except json.JSONDecodeError:
        continue
    if 'mean_enh_chamfer_distance' in row:
        rows.append(row)
rows.sort(key=lambda r: r['mean_enh_chamfer_distance'])
json.dump(rows, open('$GRID/summary_val565.json','w'), indent=2)
print('summary', len(rows), 'presets')
for r in rows[:5]:
    print(' ', r['experiment'], r['mean_enh_chamfer_distance'])
PY

python "$ROOT/scripts/enh_refine_gate.py" --grid-root "$GRID" --out-json "$GRID/gate_decision.json"
python "$ROOT/scripts/build_per_sequence_enh_refine_config.py" --grid-root "$GRID" \
  --out-json "$GRID/per_sequence_refine_config.json"

log "DONE -> $GRID/gate_decision.json"
