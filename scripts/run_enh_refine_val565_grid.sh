#!/usr/bin/env bash
# Val565 grid: multi-stage Enh refine presets + eval + gate (with CG passthrough rollback).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRID="$ROOT/output/enh_refine_grid"
PAIRS="$ROOT/data/processed/val_pairs_official_cgv2.txt"
CG_LIST="$GRID/cg_list.txt"
PDLTS_LIGHT="${PDLTS_LIGHT:-$ROOT/output/pdlts_val565/light}"
PDLTS_HEAVY="${PDLTS_HEAVY:-$ROOT/output/pdlts_val565/heavy}"
MAX_SAMPLES="${MAX_SAMPLES:-0}"
USE_CACHE="${USE_CACHE:-1}"
SKIP_INFER="${SKIP_INFER:-0}"

mkdir -p "$GRID"
cut -f1 "$PAIRS" > "$CG_LIST"
if [[ "$MAX_SAMPLES" -gt 0 ]]; then
  head -n "$MAX_SAMPLES" "$CG_LIST" > "$GRID/cg_list_subset.txt"
  CG_LIST="$GRID/cg_list_subset.txt"
fi

source /root/miniconda3/etc/profile.d/conda.sh
conda activate superpc

log() { echo "[enh_refine_grid] $(date +%H:%M:%S) $*"; }

geometry_args() {
  local preset="$1"
  local -n _out="$2"
  _out=()
  if [[ "$USE_CACHE" != "1" ]]; then
    return
  fi
  case "$preset" in
    pdlts_light*|from_dir*)
      if [[ -d "$PDLTS_LIGHT" ]] && compgen -G "$PDLTS_LIGHT/*/*.ply" >/dev/null; then
        _out=(--require-geometry-cache --geometry-fallback filter_cg --use-geometry-cache)
      fi
      ;;
    pdlts_heavy*)
      if [[ -d "$PDLTS_HEAVY" ]] && compgen -G "$PDLTS_HEAVY/*/*.ply" >/dev/null; then
        _out=(--geometry-dir "$PDLTS_HEAVY" --use-geometry-cache)
      fi
      ;;
  esac
}

PRESETS=(
  cg_passthrough
  filter_cg
  pdlts_light
  pdlts_heavy
  pdlts_light_snap0.5
  pdlts_light_snap1.0
  pdlts_light_snap1.5
  pdlts_light_snap1_fill0.6
  pdlts_light_snap1_fill1.0
  pdlts_light_pre25_snap1
  pdlts_light_snap1_post25
  pdlts_light_snap1_fill0.6_post25
  pdlts_heavy_snap1.0
  pdlts_light_snap1_adapt
)

summary_rows=()

if [[ "$SKIP_INFER" != "1" ]]; then
  for preset in "${PRESETS[@]}"; do
    out="$GRID/$preset"
    mkdir -p "$out"
    extra=()
    geometry_args "$preset" extra
    log "infer preset=$preset out=$out extra=${extra[*]:-live}"
    python "$ROOT/scripts/run_enh_refine_infer.py" \
      --cg-list "$CG_LIST" \
      --out-dir "$out" \
      --preset "$preset" \
      "${extra[@]}"
  done
fi

log "evaluating presets..."
for preset in "${PRESETS[@]}"; do
  out="$GRID/$preset"
  if [[ ! -d "$out" ]]; then
    continue
  fi
  python "$ROOT/scripts/evaluate_gc_baseline_metrics.py" \
    --pairs-file "$PAIRS" \
    --test-root "$out" \
    --max-frames "$MAX_SAMPLES" \
    --also-cg \
    --workers "${EVAL_WORKERS:-8}" \
    --out-json "$out/evaluation_gc_baseline_val565.json" \
    --out-csv "$out/evaluation_gc_baseline_val565.csv" > /dev/null 2>&1 || true

  if [[ -f "$out/evaluation_gc_baseline_val565.json" ]]; then
    python - <<PY || true
import json
try:
    d=json.load(open('$out/evaluation_gc_baseline_val565.json'))
    means=d.get('means') or {}
    ch=means.get('chamfer_distance')
    if ch is None:
        raise KeyError('missing means.chamfer_distance')
    row={
      'experiment': '$preset',
      'mean_enh_chamfer_distance': ch,
      'improvement_cg_minus_enh': d.get('mean_improvement_cg_minus_enh'),
    }
    print(json.dumps(row))
except Exception as e:
    import sys
    print(json.dumps({'experiment':'$preset','error':str(e)}), file=sys.stderr)
PY
  fi
done > "$GRID/_summary_lines.jsonl" 2>> "$GRID/eval_errors.log"

python - <<PY
import json
rows=[]
for line in open('$GRID/_summary_lines.jsonl'):
    line=line.strip()
    if not line:
        continue
    try:
        row=json.loads(line)
    except json.JSONDecodeError:
        continue
    if 'mean_enh_chamfer_distance' in row:
        rows.append(row)
rows.sort(key=lambda r: r['mean_enh_chamfer_distance'])
json.dump(rows, open('$GRID/summary_val565.json','w'), indent=2)
print('summary', len(rows), 'experiments')
if rows:
    print('best', rows[0]['experiment'], rows[0]['mean_enh_chamfer_distance'])
PY

python "$ROOT/scripts/enh_refine_gate.py" --grid-root "$GRID"
python "$ROOT/scripts/build_per_sequence_enh_refine_config.py" --grid-root "$GRID"

log "DONE -> $GRID/gate_decision.json"
