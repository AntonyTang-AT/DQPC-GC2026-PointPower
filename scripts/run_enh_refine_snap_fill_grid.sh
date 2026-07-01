#!/usr/bin/env bash
# CPU-only snap/fill fine grid on cached PD-LTS light (val565).
# Uses PHASE2D presets from enh_refine_config.py.
#
# Examples:
#   bash scripts/run_enh_refine_snap_fill_grid.sh
#   SKIP_INFER=1 bash scripts/run_enh_refine_snap_fill_grid.sh   # eval+gate only
#   PRESET_FILTER='fill0.8' bash scripts/run_enh_refine_snap_fill_grid.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRID="${GRID_ROOT:-$ROOT/output/enh_refine_snap_fill_grid}"
PAIRS="$ROOT/data/processed/val_pairs_official_cgv2.txt"
CG_LIST="$GRID/cg_list.txt"
SKIP_INFER="${SKIP_INFER:-0}"
EVAL_WORKERS="${EVAL_WORKERS:-16}"
PARALLEL_EVAL="${PARALLEL_EVAL:-1}"
PRESET_FILTER="${PRESET_FILTER:-}"
PARALLEL_PRESETS="${PARALLEL_PRESETS:-1}"
FAST_GRID="${FAST_GRID:-0}"

mkdir -p "$GRID"
cut -f1 "$PAIRS" > "$CG_LIST"

source /root/miniconda3/etc/profile.d/conda.sh
conda activate superpc
export PYTHONPATH="$ROOT/scripts:${PYTHONPATH:-}"
export OPENBLAS_NUM_THREADS="${OPENBLAS_NUM_THREADS:-4}"
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-4}"

log() { echo "[snap_fill_grid] $(date +%H:%M:%S) $*"; }

if [[ "$FAST_GRID" == "1" ]]; then
  mapfile -t PRESETS < <(python - <<PY
# Narrow search around winner snap1.0 fill0.6 (skip fill0.6 — reuse phase2)
presets = [
    "pdlts_light_snap1_fill0.5",
    "pdlts_light_snap1_fill0.7",
    "pdlts_light_snap1_fill0.8",
    "pdlts_light_snap1_fill1.0",
    "pdlts_light_snap1.2_fill0.6",
    "pdlts_light_snap1_adapt",
]
for p in presets:
    print(p)
PY
)
else
  mapfile -t PRESETS < <(python - <<PY
from enh_refine_config import PHASE2D_PRESETS
for p in PHASE2D_PRESETS:
    print(p)
PY
)
fi

if [[ -n "$PRESET_FILTER" ]]; then
  filtered=()
  for p in "${PRESETS[@]}"; do
    [[ "$p" == *"$PRESET_FILTER"* ]] && filtered+=("$p")
  done
  PRESETS=("${filtered[@]}")
fi

log "presets=${#PRESETS[@]} grid=$GRID parallel_infer=$PARALLEL_PRESETS parallel_eval=$PARALLEL_EVAL fast=$FAST_GRID"

link_phase2_baseline() {
  local preset="$1"
  local out="$GRID/$preset"
  local phase2="$ROOT/output/enh_refine_phase2/pdlts_light_snap1_fill0.6"
  if [[ "$preset" == "pdlts_light_snap1_fill0.6" && -d "$phase2" ]]; then
    log "reuse phase2 cache for $preset"
    mkdir -p "$out"
    if [[ ! -f "$out/evaluation_gc_baseline_val565.json" && -f "$phase2/evaluation_gc_baseline_val565.json" ]]; then
      cp -a "$phase2/evaluation_gc_baseline_val565.json" "$out/"
      cp -a "$phase2/evaluation_gc_baseline_val565.csv" "$out/" 2>/dev/null || true
    fi
    if [[ ! -f "$out/infer_meta.json" && -f "$phase2/infer_meta.json" ]]; then
      cp -a "$phase2/infer_meta.json" "$out/"
    fi
    return 0
  fi
  return 1
}

run_one_infer() {
  local preset="$1"
  local out="$GRID/$preset"
  if link_phase2_baseline "$preset"; then
    return 0
  fi
  if [[ -f "$out/infer_meta.json" ]]; then
    log "skip infer (done) preset=$preset"
    return 0
  fi
  mkdir -p "$out"
  log "infer preset=$preset"
  python "$ROOT/scripts/run_enh_refine_infer.py" \
    --cg-list "$CG_LIST" \
    --out-dir "$out" \
    --preset "$preset" \
    --require-geometry-cache \
    --geometry-fallback filter_cg \
    --use-geometry-cache
}

run_one_eval() {
  local preset="$1"
  local out="$GRID/$preset"
  [[ -d "$out" ]] || return 0
  if [[ -f "$out/evaluation_gc_baseline_val565.json" ]]; then
    log "skip eval (done) preset=$preset"
    return 0
  fi
  log "eval preset=$preset workers=$EVAL_WORKERS"
  python "$ROOT/scripts/evaluate_gc_baseline_metrics.py" \
    --pairs-file "$PAIRS" \
    --test-root "$out" \
    --workers "$EVAL_WORKERS" \
    --also-cg \
    --out-json "$out/evaluation_gc_baseline_val565.json" \
    --out-csv "$out/evaluation_gc_baseline_val565.csv"
}

if [[ "$SKIP_INFER" != "1" ]]; then
  if [[ "$PARALLEL_PRESETS" -le 1 ]]; then
    for preset in "${PRESETS[@]}"; do
      run_one_infer "$preset"
    done
  else
    log "parallel infer workers=$PARALLEL_PRESETS"
    active=0
    for preset in "${PRESETS[@]}"; do
      while (( active >= PARALLEL_PRESETS )); do
        if wait -n 2>/dev/null; then
          active=$((active - 1))
        else
          wait || true
          active=0
        fi
      done
      run_one_infer "$preset" &
      active=$((active + 1))
    done
    wait || true
  fi
fi

: > "$GRID/_summary_lines.jsonl"
if [[ "$PARALLEL_EVAL" -le 1 ]]; then
  for preset in "${PRESETS[@]}"; do
    run_one_eval "$preset"
    out="$GRID/$preset"
    if [[ -f "$out/evaluation_gc_baseline_val565.json" ]]; then
      python - <<PY || true
import json
d=json.load(open('$out/evaluation_gc_baseline_val565.json'))
s=d.get('summary', d)
ch=(s.get('means') or {}).get('chamfer_distance')
if ch is not None:
    print(json.dumps({'experiment':'$preset','mean_enh_chamfer_distance':ch,
                      'improvement_cg_minus_enh':s.get('mean_improvement_cg_minus_enh')}))
PY
    fi
  done >> "$GRID/_summary_lines.jsonl"
else
  log "parallel eval workers=$PARALLEL_EVAL eval_threads=$EVAL_WORKERS"
  active=0
  for preset in "${PRESETS[@]}"; do
    while (( active >= PARALLEL_EVAL )); do
      if wait -n 2>/dev/null; then
        active=$((active - 1))
      else
        wait || true
        active=0
      fi
    done
    (
      run_one_eval "$preset"
      out="$GRID/$preset"
      if [[ -f "$out/evaluation_gc_baseline_val565.json" ]]; then
        python - <<PY || true
import json
d=json.load(open('$out/evaluation_gc_baseline_val565.json'))
s=d.get('summary', d)
ch=(s.get('means') or {}).get('chamfer_distance')
if ch is not None:
    print(json.dumps({'experiment':'$preset','mean_enh_chamfer_distance':ch,
                      'improvement_cg_minus_enh':s.get('mean_improvement_cg_minus_enh')}))
PY
      fi
    ) >> "$GRID/_summary_lines.jsonl" &
    active=$((active + 1))
  done
  wait || true
fi

# rebuild summary from all eval json (includes prior runs + phase2 link)
python - <<PY
import json, os, glob
rows=[]
grid='$GRID'
for ev in sorted(glob.glob(grid + '/*/evaluation_gc_baseline_val565.json')):
    preset=os.path.basename(os.path.dirname(ev))
    d=json.load(open(ev))
    s=d.get('summary', d)
    ch=(s.get('means') or {}).get('chamfer_distance')
    if ch is None: continue
    rows.append({'experiment': preset, 'mean_enh_chamfer_distance': ch,
                 'improvement_cg_minus_enh': s.get('mean_improvement_cg_minus_enh')})
rows.sort(key=lambda r: r['mean_enh_chamfer_distance'])
json.dump(rows, open(grid + '/summary_val565.json','w'), indent=2)
with open(grid + '/_summary_lines.jsonl','w') as f:
    for r in rows:
        f.write(json.dumps(r)+'\n')
print('summary', len(rows), 'presets')
for r in rows[:8]:
    print(f"  {r['experiment']:40s} {r['mean_enh_chamfer_distance']:.4f}  improve={r.get('improvement_cg_minus_enh')}")
PY

python "$ROOT/scripts/enh_refine_gate.py" --grid-root "$GRID" --out-json "$GRID/gate_decision.json"
python "$ROOT/scripts/build_per_sequence_enh_refine_config.py" \
  --grid-root "$GRID" \
  --out-json "$GRID/per_sequence_refine_config.json"

log "DONE -> $GRID/gate_decision.json"
