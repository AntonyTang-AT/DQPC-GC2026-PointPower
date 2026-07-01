#!/usr/bin/env bash
# P0/P1/P2 val565 experiments: per-seq, rollback, post25, adapt, heavy, density, bidir.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRID="${GRID_ROOT:-$ROOT/output/enh_refine_p0_p1_p2}"
PAIRS="$ROOT/data/processed/val_pairs_official_cgv2.txt"
CG_LIST="$GRID/cg_list.txt"
EVAL_WORKERS="${EVAL_WORKERS:-16}"

mkdir -p "$GRID"
cut -f1 "$PAIRS" > "$CG_LIST"

source /root/miniconda3/etc/profile.d/conda.sh
conda activate superpc
export PYTHONPATH="$ROOT/scripts:${PYTHONPATH:-}"
export OPENBLAS_NUM_THREADS="${OPENBLAS_NUM_THREADS:-2}"
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-2}"

log() { echo "[p0_p1_p2] $(date +%H:%M:%S) $*"; }

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

COMMON_CACHE=(
  --require-geometry-cache
  --geometry-fallback filter_cg
  --use-geometry-cache
)

log "=== build configs ==="
python "$ROOT/scripts/build_per_sequence_snap_fill_templates.py" \
  --grid-root "$ROOT/output/enh_refine_snap_fill_grid" \
  --out-json "$GRID/per_seq_config.json" || \
python "$ROOT/scripts/build_per_sequence_snap_fill_templates.py" \
  --heuristic-only \
  --out-json "$GRID/per_seq_config.json"

python "$ROOT/scripts/build_per_frame_refine_decision.py" \
  --eval-json "$ROOT/output/enh_refine_phase2/pdlts_light_snap1_fill0.6/evaluation_gc_baseline_val565.json" \
  --out-dir "$GRID/frame_decision"

log "=== P0 per-sequence ==="
run_infer p0_perseq \
  --preset pdlts_light_snap1_fill0.6 \
  --per-seq-config "$GRID/per_seq_config.json" \
  "${COMMON_CACHE[@]}"
run_eval p0_perseq

log "=== P0 per-seq + frame proxy rollback ==="
run_infer p0_perseq_rollback \
  --preset pdlts_light_snap1_fill0.6 \
  --per-seq-config "$GRID/per_seq_config.json" \
  --frame-proxy-json "$GRID/frame_decision/proxy_rules.json" \
  "${COMMON_CACHE[@]}"
run_eval p0_perseq_rollback

log "=== P1 post25 / adapt ==="
for preset in pdlts_light_snap1_fill0.6_post25 pdlts_light_snap1_adapt; do
  src="$ROOT/output/enh_refine_phase2/$preset"
  out="$GRID/$preset"
  if [[ -d "$src" && -f "$src/infer_meta.json" && ! -f "$out/infer_meta.json" ]]; then
    log "reuse phase2 infer $preset"
    mkdir -p "$out"
    cp -a "$src"/* "$out/" 2>/dev/null || true
  else
    run_infer "$preset" --preset "$preset" "${COMMON_CACHE[@]}"
  fi
  run_eval "$preset"
done

log "=== P1 heavy snap1 fill0.6 (partial cache) ==="
python - <<PY
import json, os
from enh_refine_config import resolve_preset
cfg = resolve_preset("pdlts_heavy_snap1.0").to_dict()
cfg["fill_mm"] = 0.6
cfg["name"] = "p1_pdlts_heavy_snap1_fill0.6"
out = "$GRID/p1_pdlts_heavy_snap1_fill0.6"
os.makedirs(out, exist_ok=True)
json.dump(cfg, open(out + "/pipeline_config.json", "w"), indent=2)
PY
run_infer p1_pdlts_heavy_snap1_fill0.6 \
  --config-json "$GRID/p1_pdlts_heavy_snap1_fill0.6/pipeline_config.json" \
  --require-geometry-cache \
  --geometry-fallback filter_cg \
  --use-geometry-cache \
  --geometry-dir "$ROOT/output/pdlts_val565/heavy"
run_eval p1_pdlts_heavy_snap1_fill0.6

log "=== P1 geometry oracle (light vs heavy, CPU) ==="
python "$ROOT/scripts/analyze_geometry_oracle.py" \
  --workers "$EVAL_WORKERS" \
  --out-json "$GRID/geometry_oracle_light_vs_heavy.json" || log "oracle partial/failed"

log "=== P2 density / bidir / combined ==="
for preset in pdlts_light_snap1_fill0.6_density pdlts_light_snap1_fill0.6_bidir pdlts_light_snap1_fill0.6_combined; do
  run_infer "$preset" --preset "$preset" "${COMMON_CACHE[@]}"
  run_eval "$preset"
done

log "=== summary + gate ==="
python - <<PY
import json, os, glob
rows = []
grid = "$GRID"
cg_ref = 17.551553246708043
for ev in sorted(glob.glob(grid + "/*/evaluation_gc_baseline_val565.json")):
    name = os.path.basename(os.path.dirname(ev))
    d = json.load(open(ev))
    s = d.get("summary", d)
    ch = (s.get("means") or {}).get("chamfer_distance")
    if ch is None:
        continue
    imp = cg_ref - float(ch)
    rows.append({"experiment": name, "mean_enh_chamfer_distance": float(ch), "improvement_cg_minus_enh": imp})
rows.sort(key=lambda r: r["mean_enh_chamfer_distance"])
json.dump(rows, open(grid + "/summary_val565.json", "w"), indent=2)
print("=== ranking ===")
for r in rows:
    print(f"  {r['experiment']:40s} {r['mean_enh_chamfer_distance']:.4f}  improve={r['improvement_cg_minus_enh']:+.4f}")
oracle = json.load(open(grid + "/frame_decision/oracle_analysis.json"))
print("=== oracle rollback upper bound ===")
print(json.dumps(oracle.get("stats", {}), indent=2))
if os.path.isfile(grid + "/geometry_oracle_light_vs_heavy.json"):
    g = json.load(open(grid + "/geometry_oracle_light_vs_heavy.json"))
    print("=== geometry oracle ===")
    print(json.dumps(g.get("summary", {}), indent=2))
PY

python "$ROOT/scripts/enh_refine_gate.py" \
  --grid-root "$GRID" \
  --out-json "$GRID/gate_decision.json"

python "$ROOT/scripts/build_per_sequence_enh_refine_config.py" \
  --grid-root "$GRID" \
  --out-json "$GRID/per_sequence_refine_config.json"

log "DONE -> $GRID/gate_decision.json"
