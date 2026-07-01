#!/usr/bin/env bash
# Six-GPU orchestrator: finish pending infer (sharded) + VH tune (3 configs x 2 shards).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRID="${GRID_ROOT:-$ROOT/output/enh_refine_val565_selection}"
PAIRS="$ROOT/data/processed/val_pairs_official_cgv2.txt"
CG_LIST="$GRID/cg_list.txt"
WINNER="${WINNER_PRESET:-pdlts_light_snap1_fill0.6_density}"
NUM_SHARDS=6
GPUS="0,1,2,3,4,5"
LOGDIR="$GRID/logs"
EVAL_WORKERS=16

source /root/miniconda3/etc/profile.d/conda.sh
conda activate superpc
export PYTHONPATH="$ROOT/scripts:${PYTHONPATH:-}"

mkdir -p "$LOGDIR" "$GRID/vh_configs"
[[ -f "$CG_LIST" ]] || cut -f1 "$PAIRS" > "$CG_LIST"

log() { echo "[6gpu] $(date +%H:%M:%S) $*"; }

run_eval() {
  local out="$1"
  [[ -f "$out/evaluation_gc_baseline_val565.json" ]] && return 0
  log "eval $(basename "$out")"
  python "$ROOT/scripts/evaluate_gc_baseline_metrics.py" \
    --pairs-file "$PAIRS" \
    --test-root "$out" \
    --workers "$EVAL_WORKERS" \
    --also-cg \
    --out-json "$out/evaluation_gc_baseline_val565.json" \
    --out-csv "$out/evaluation_gc_baseline_val565.csv"
}

# --- Phase A: finish hybrid_density on 6 shards ---
HYBRID_OUT="$GRID/hybrid_pdlts_superpc_snap1_fill0.6_density"
if [[ ! -f "$HYBRID_OUT/evaluation_gc_baseline_val565.json" ]]; then
  n_done=$(find "$HYBRID_OUT" -name "*.ply" 2>/dev/null | wc -l)
  if [[ "$n_done" -lt 565 ]]; then
    log "hybrid_density $n_done/565 — kill single-worker infer, relaunch 6-shard"
    pkill -f "run_enh_refine_infer.py.*hybrid_pdlts_superpc_snap1_fill0.6_density" 2>/dev/null || true
    sleep 2
    PRESET=hybrid_pdlts_superpc_snap1_fill0.6_density \
      OUT_DIR="$HYBRID_OUT" \
      CG_LIST="$CG_LIST" \
      NUM_SHARDS=$NUM_SHARDS GPUS="$GPUS" LOGDIR="$LOGDIR" \
      bash "$ROOT/scripts/run_enh_refine_sharded.sh"
  fi
  run_eval "$HYBRID_OUT"
fi

# --- Phase B: VH tune — 3 configs, each 2 shards on 6 GPUs ---
build_vh_cfg() {
  local tag="$1" geom="$2" fill="$3" snap="$4"
  local out="$GRID/vh_configs/${tag}_per_seq.json"
  python3 - <<PY
import json
from enh_refine_config import resolve_preset
base = resolve_preset("$WINNER").to_dict()
vh = {"fill_mm": float("$fill"), "snap_mm": float("$snap"), "fill_mode": "density_adaptive"}
if "$geom" not in ("", "inherit"):
    vh["geometry"] = "$geom"
json.dump({"source":"vh_tune","winner":"$WINNER","default":base,"sequences":{"VictoryHeart":vh}},
          open("$out","w"), indent=2)
PY
}

run_vh_sharded() {
  local tag="$1" cfg="$2" gpu_a="$3" gpu_b="$4"
  local name="vh_${tag}"
  local out="$GRID/$name"
  mkdir -p "$out"
  if [[ -f "$out/evaluation_gc_baseline_val565.json" ]]; then
    log "skip $name (eval done)"
    return 0
  fi
  local sd="$LOGDIR/shards_${name}"
  python3 - <<PY
import os
paths=[l.strip().split()[0] for l in open("$CG_LIST") if l.strip()]
n=2
os.makedirs("$sd", exist_ok=True)
for sid in range(n):
    bucket=[p for i,p in enumerate(paths) if i % n == sid]
    open(os.path.join("$sd", f"cg_shard_{sid}.txt"), "w").write("\n".join(bucket)+"\n")
PY
  local args=(
    --require-geometry-cache --geometry-fallback filter_cg
    --use-geometry-cache --geometry-dir "$ROOT/output/pdlts_val565/light"
    --out-dir "$out" --no-save-config
    --preset "$WINNER" --per-seq-config "$cfg"
  )
  log "VH $name GPU${gpu_a}+${gpu_b}"
  CUDA_VISIBLE_DEVICES="$gpu_a" python "$ROOT/scripts/run_enh_refine_infer.py" \
    --cg-list "$sd/cg_shard_0.txt" "${args[@]}" \
    > "$LOGDIR/${name}_s0.log" 2>&1 &
  local p0=$!
  CUDA_VISIBLE_DEVICES="$gpu_b" python "$ROOT/scripts/run_enh_refine_infer.py" \
    --cg-list "$sd/cg_shard_1.txt" "${args[@]}" \
    > "$LOGDIR/${name}_s1.log" 2>&1 &
  local p1=$!
  wait "$p0" "$p1"
  python "$ROOT/scripts/run_enh_refine_infer.py" \
    --cg-list "$CG_LIST" \
    --out-dir "$out" \
    --require-geometry-cache --geometry-fallback filter_cg \
    --use-geometry-cache --geometry-dir "$ROOT/output/pdlts_val565/light" \
    --preset "$WINNER" --per-seq-config "$cfg" \
    2>&1 | tail -2
  run_eval "$out"
}

build_vh_cfg passthrough passthrough_cg 0.6 1.0
build_vh_cfg fill04 inherit 0.4 1.0
build_vh_cfg snap0 inherit 0.6 0.0

log "VH tune: 3 configs parallel (2 shards each = 6 GPU workers)"
run_vh_sharded passthrough "$GRID/vh_configs/passthrough_per_seq.json" 0 1 &
p1=$!
run_vh_sharded fill04 "$GRID/vh_configs/fill04_per_seq.json" 2 3 &
p2=$!
run_vh_sharded snap0 "$GRID/vh_configs/snap0_per_seq.json" 4 5 &
p3=$!
wait "$p1" "$p2" "$p3"

# --- Phase C: gate ---
log "gate summary"
STAGE=gate GRID_ROOT="$GRID" bash "$ROOT/scripts/run_val565_selection.sh"

log "DONE — see $GRID/gate_decision.json"
