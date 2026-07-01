#!/usr/bin/env bash
# VH conservative tuning on val565 after main selection winner is known.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRID="${GRID_ROOT:-$ROOT/output/enh_refine_val565_selection}"
WINNER_PRESET="${WINNER_PRESET:-pdlts_light_snap1_fill0.6_density}"
PAIRS="$ROOT/data/processed/val_pairs_official_cgv2.txt"
CG_LIST="$GRID/cg_list.txt"
EVAL_WORKERS="${EVAL_WORKERS:-16}"

source /root/miniconda3/etc/profile.d/conda.sh
conda activate superpc
export PYTHONPATH="$ROOT/scripts:${PYTHONPATH:-}"

mkdir -p "$GRID/vh_configs" "$GRID/logs"
[[ -f "$CG_LIST" ]] || cut -f1 "$PAIRS" > "$CG_LIST"

COMMON=(
  --require-geometry-cache
  --geometry-fallback filter_cg
  --use-geometry-cache
  --geometry-dir "$ROOT/output/pdlts_val565/light"
)

build_vh_config() {
  local tag="$1"
  local vh_geometry="$2"
  local vh_fill="$3"
  local vh_snap="$4"
  local vh_fill_mode="$5"
  local out="$GRID/vh_configs/${tag}_per_seq.json"
  python3 - <<PY
import json, os
from enh_refine_config import resolve_preset
base = resolve_preset("$WINNER_PRESET").to_dict()
base["fill_mode"] = base.get("fill_mode", "fixed")
  doc = {
  "source": "vh_tune",
  "winner": "$WINNER_PRESET",
  "default": base,
  "sequences": {
    "VictoryHeart": {
      **({"geometry": "$vh_geometry"} if "$vh_geometry" not in ("", "inherit") else {}),
      "fill_mm": float("$vh_fill"),
      "snap_mm": float("$vh_snap"),
      "fill_mode": "$vh_fill_mode",
    }
  }
}
json.dump(doc, open("$out", "w"), indent=2)
print("$out")
PY
}

run_vh() {
  local tag="$1"
  local cfg="$2"
  local gpu="$3"
  local name="vh_${tag}"
  local out="$GRID/$name"
  local log="$GRID/logs/${name}.log"
  if [[ -f "$out/evaluation_gc_baseline_val565.json" ]]; then
    echo "[skip] $name done"
    return 0
  fi
  echo "[start] $name GPU=$gpu"
  (
    export CUDA_VISIBLE_DEVICES="$gpu"
    mkdir -p "$out"
    python "$ROOT/scripts/run_enh_refine_infer.py" \
      --cg-list "$CG_LIST" \
      --out-dir "$out" \
      --preset "$WINNER_PRESET" \
      --per-seq-config "$cfg" \
      "${COMMON[@]}"
    python "$ROOT/scripts/evaluate_gc_baseline_metrics.py" \
      --pairs-file "$PAIRS" \
      --test-root "$out" \
      --workers "$EVAL_WORKERS" \
      --also-cg \
      --out-json "$out/evaluation_gc_baseline_val565.json" \
      --out-csv "$out/evaluation_gc_baseline_val565.csv"
  ) > "$log" 2>&1
}

build_vh_config passthrough passthrough_cg 0.6 1.0 density_adaptive
build_vh_config fill04 inherit 0.4 1.0 density_adaptive
build_vh_config snap0 inherit 0.6 0.0 density_adaptive

PIDS=()
run_vh passthrough "$GRID/vh_configs/passthrough_per_seq.json" 3 & PIDS+=($!)
run_vh fill04 "$GRID/vh_configs/fill04_per_seq.json" 4 & PIDS+=($!)
run_vh snap0 "$GRID/vh_configs/snap0_per_seq.json" 5 & PIDS+=($!)

FAIL=0
for pid in "${PIDS[@]}"; do wait "$pid" || FAIL=1; done
[[ "$FAIL" -eq 0 ]] || exit 1
echo "[vh_tune] done -> $GRID/vh_*"
