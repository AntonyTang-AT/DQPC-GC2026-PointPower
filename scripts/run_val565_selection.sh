#!/usr/bin/env bash
# val565 selection grid: temporal / hybrid / fp_migrated vs density baseline.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRID="${GRID_ROOT:-$ROOT/output/enh_refine_val565_selection}"
PAIRS="$ROOT/data/processed/val_pairs_official_cgv2.txt"
CG_LIST="$GRID/cg_list.txt"
STAGE="${STAGE:-all}"
EVAL_WORKERS="${EVAL_WORKERS:-16}"
DENSITY_SRC="$ROOT/output/enh_refine_p0_p1_p2/pdlts_light_snap1_fill0.6_density"
STATUS="$GRID/selection_status.json"

source /root/miniconda3/etc/profile.d/conda.sh
conda activate superpc
export PYTHONPATH="$ROOT/scripts:${PYTHONPATH:-}"
export OPENBLAS_NUM_THREADS="${OPENBLAS_NUM_THREADS:-2}"
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-2}"

mkdir -p "$GRID"
[[ -f "$CG_LIST" ]] || cut -f1 "$PAIRS" > "$CG_LIST"

log() { echo "[val565_sel] $(date +%H:%M:%S) $*"; }

COMMON_CACHE=(
  --require-geometry-cache
  --geometry-fallback filter_cg
  --use-geometry-cache
  --geometry-dir "$ROOT/output/pdlts_val565/light"
)

run_infer() {
  local name="$1"
  shift
  local out="$GRID/$name"
  mkdir -p "$out"
  if [[ -f "$out/infer_meta.json" ]]; then
    log "skip infer (done) $name"
    return 0
  fi
  log "infer $name"
  python "$ROOT/scripts/run_enh_refine_infer.py" \
    --cg-list "$CG_LIST" \
    --out-dir "$out" \
    "$@"
}

run_eval() {
  local name="$1"
  local out="$GRID/$name"
  [[ -d "$out" ]] || return 0
  if [[ -f "$out/evaluation_gc_baseline_val565.json" ]]; then
    log "skip eval (done) $name"
    return 0
  fi
  log "eval $name workers=$EVAL_WORKERS"
  python "$ROOT/scripts/evaluate_gc_baseline_metrics.py" \
    --pairs-file "$PAIRS" \
    --test-root "$out" \
    --workers "$EVAL_WORKERS" \
    --also-cg \
    --out-json "$out/evaluation_gc_baseline_val565.json" \
    --out-csv "$out/evaluation_gc_baseline_val565.csv"
}

run_temporal() {
  local win="$1"
  local name="density_temporal_w${win}"
  local out="$GRID/$name"
  if [[ -f "$out/evaluation_gc_baseline_val565.json" ]]; then
    log "skip temporal (done) $name"
    return 0
  fi
  log "temporal w=$win -> $name"
  TEMPORAL_WINDOW="$win" EVAL=1 bash "$ROOT/scripts/run_enh_cpu_post.sh" \
    "$DENSITY_SRC" "$out"
}

prep_baseline() {
  local out="$GRID/pdlts_light_snap1_fill0.6_density"
  mkdir -p "$out"
  if [[ ! -f "$out/evaluation_gc_baseline_val565.json" ]]; then
    cp "$DENSITY_SRC/evaluation_gc_baseline_val565.json" "$out/"
    cp "$DENSITY_SRC/pipeline_config.json" "$out/" 2>/dev/null || true
  fi
}

stage_prep() {
  prep_baseline
  log "prep done -> $GRID"
}

stage_temporal() {
  for w in 3 5; do
    run_temporal "$w"
  done
}

stage_smoke() {
  for preset in hybrid_pdlts_superpc_snap1_fill0.6_density hybrid_pdlts_superpc_snap1_fill0.6_superfill; do
    local out="$GRID/_smoke_${preset}"
    mkdir -p "$out"
    head -2 "$CG_LIST" > "$out/cg_list_smoke.txt"
    log "smoke infer $preset (2 frames)"
    python "$ROOT/scripts/run_enh_refine_infer.py" \
      --cg-list "$out/cg_list_smoke.txt" \
      --out-dir "$out" \
      --preset "$preset" \
      "${COMMON_CACHE[@]}"
  done
}

stage_infer() {
  local preset gpu
  if [[ -n "${PRESET:-}" ]]; then
    run_infer "$PRESET" --preset "$PRESET" "${COMMON_CACHE[@]}"
    run_eval "$PRESET"
    return 0
  fi
  local presets=(
    hybrid_pdlts_superpc_snap1_fill0.6_density
    hybrid_pdlts_superpc_snap1_fill0.6_superfill
    fp_migrated_pre25_density
  )
  local pids=()
  for i in "${!presets[@]}"; do
    preset="${presets[$i]}"
    gpu="${GPUS:-0,1,2}"
    gpu_id=$(echo "$gpu" | cut -d, -f$((i + 1)))
    (
      export CUDA_VISIBLE_DEVICES="${gpu_id:-0}"
      run_infer "$preset" --preset "$preset" "${COMMON_CACHE[@]}"
      run_eval "$preset"
    ) &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid" || exit 1; done
}

stage_gate() {
  python3 - <<PY
import json, os, glob
rows = []
grid = "$GRID"
cg_ref = 17.551553246708043
for ev in sorted(glob.glob(grid + "/*/evaluation_gc_baseline_val565.json")):
    name = os.path.basename(os.path.dirname(ev))
    if name.startswith("_"):
        continue
    d = json.load(open(ev))
    s = d.get("summary", d)
    ch = (s.get("means") or {}).get("chamfer_distance")
    if ch is None:
        ch = s.get("mean_enh_chamfer_distance")
    if ch is None:
        continue
    imp = cg_ref - float(ch)
    rows.append({"experiment": name, "mean_enh_chamfer_distance": float(ch), "improvement_cg_minus_enh": imp})
rows.sort(key=lambda r: r["mean_enh_chamfer_distance"])
json.dump(rows, open(grid + "/summary_val565.json", "w"), indent=2)
print("=== ranking ===")
for r in rows:
    print(f"  {r['experiment']:45s} {r['mean_enh_chamfer_distance']:.4f}  improve={r['improvement_cg_minus_enh']:+.4f}")
PY
  python "$ROOT/scripts/enh_refine_gate.py" \
    --grid-root "$GRID" \
    --out-json "$GRID/gate_decision.json"
}

case "$STAGE" in
  prep) stage_prep ;;
  temporal) stage_temporal ;;
  smoke) stage_smoke ;;
  infer) stage_infer ;;
  eval) run_eval "${PRESET:?set PRESET}" ;;
  gate) stage_gate ;;
  all)
    stage_prep
    stage_temporal &
    tp=$!
    stage_smoke
    wait "$tp" || exit 1
    stage_infer
    stage_gate
    ;;
  *) echo "Unknown STAGE=$STAGE (prep|temporal|smoke|infer|eval|gate|all)" >&2; exit 1 ;;
esac

log "DONE STAGE=$STAGE -> $GRID"
