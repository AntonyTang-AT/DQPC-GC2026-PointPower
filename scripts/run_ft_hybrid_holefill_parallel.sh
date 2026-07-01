#!/usr/bin/env bash
# Parallel val565: CG-hole secondary fill (line A) vs fill-first+post-SOR (line B).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GEOMETRY_DIR="${GEOMETRY_DIR:-$ROOT/output/pdlts_finetune_uvg/val565/light}"
GEOMETRY_SECONDARY_DIR="${GEOMETRY_SECONDARY_DIR:-$ROOT/output/submission_candidate}"
BASE="${BASE:-$ROOT/output/ft_val565_fusion}"
LOGDIR="${LOGDIR:-$BASE/logs_holefill_parallel}"
NUM_SHARDS="${NUM_SHARDS:-32}"
EVAL_WORKERS="${EVAL_WORKERS:-16}"
FORCE_RERUN="${FORCE_RERUN:-0}"

mkdir -p "$LOGDIR"

run_one() {
  local preset="$1"
  local out="$2"
  local log="$LOGDIR/${preset}.log"
  echo "[holefill_parallel] start preset=$preset -> $out"
  env PRESET="$preset" OUT_DIR="$out" \
    GEOMETRY_DIR="$GEOMETRY_DIR" GEOMETRY_SECONDARY_DIR="$GEOMETRY_SECONDARY_DIR" \
    NUM_SHARDS="$NUM_SHARDS" EVAL_WORKERS="$EVAL_WORKERS" FORCE_RERUN="$FORCE_RERUN" \
    bash "$ROOT/scripts/run_ft_fusion_one.sh" >>"$log" 2>&1
  echo "[holefill_parallel] done preset=$preset"
}

export -f run_one
export ROOT GEOMETRY_DIR GEOMETRY_SECONDARY_DIR LOGDIR NUM_SHARDS EVAL_WORKERS FORCE_RERUN

PRESET_A="${PRESET_A:-holefill_secondary_cg_hybrid_pdlts_superpc_snap1_fill0.6_density}"
PRESET_B="${PRESET_B:-holefill_first_secondary_cg_hybrid_pdlts_superpc_fill0.6_post25_density}"
OUT_A="${OUT_A:-$BASE/holefill_secondary_cg_snap1_fill0.6_density}"
OUT_B="${OUT_B:-$BASE/holefill_first_fill0.6_post25_density}"

echo "[holefill_parallel] A=$PRESET_A"
echo "[holefill_parallel] B=$PRESET_B"
echo "[holefill_parallel] logs=$LOGDIR"

run_one "$PRESET_A" "$OUT_A" &
pid_a=$!
run_one "$PRESET_B" "$OUT_B" &
pid_b=$!

wait "$pid_a"
wait "$pid_b"

echo "[holefill_parallel] both finished"
for out in "$OUT_A" "$OUT_B"; do
  ev="$out/evaluation_gc_baseline_val565.json"
  if [[ -f "$ev" ]]; then
    python3 - <<PY
import json
d=json.load(open("$ev"))
print("$out", "CD=", d["means"]["chamfer_distance"])
PY
  fi
done
