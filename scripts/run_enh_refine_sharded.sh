#!/usr/bin/env bash
# Run enh refine infer split across N CPU shards (geometry-cache path is CPU-bound).
#
# Usage:
#   PRESET=region_hybrid_pdlts_superpc_snap1_fill0.6_density \
#   OUT_DIR=output/enh_refine_val565_selection/region_hybrid_... \
#   bash scripts/run_enh_refine_sharded.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=cpu_parallel_defaults.sh
source "$ROOT/scripts/cpu_parallel_defaults.sh"

CG_LIST="${CG_LIST:-$ROOT/data/processed/val_pairs_official_cgv2.txt}"
GEOMETRY_DIR="${GEOMETRY_DIR:-$ROOT/output/pdlts_val565/light}"
OUT_DIR="${OUT_DIR:?set OUT_DIR}"
PRESET="${PRESET:-}"
CONFIG_JSON="${CONFIG_JSON:-}"
PER_SEQ_CONFIG="${PER_SEQ_CONFIG:-}"
LOGDIR="${LOGDIR:-$(dirname "$OUT_DIR")/logs}"
SHARD_DIR="${SHARD_DIR:-$LOGDIR/shards_$(basename "$OUT_DIR")}"

mkdir -p "$OUT_DIR" "$LOGDIR" "$SHARD_DIR"

source /root/miniconda3/etc/profile.d/conda.sh
conda activate superpc
export PYTHONPATH="$ROOT/scripts:${PYTHONPATH:-}"

echo "[shard] NPROC=$NPROC NUM_SHARDS=$NUM_SHARDS OMP=$OMP_NUM_THREADS OUT=$OUT_DIR"

python3 - <<PY
import os
cg_list = "$CG_LIST"
shard_dir = "$SHARD_DIR"
n = int("$NUM_SHARDS")
paths = []
with open(cg_list, encoding="utf-8") as f:
    for ln in f:
        ln = ln.strip()
        if not ln or ln.startswith("#"):
            continue
        paths.append(ln.split("\t")[0])
buckets = [[] for _ in range(n)]
for i, p in enumerate(paths):
    buckets[i % n].append(p)
os.makedirs(shard_dir, exist_ok=True)
for sid, bucket in enumerate(buckets):
    with open(os.path.join(shard_dir, f"cg_shard_{sid}.txt"), "w", encoding="utf-8") as out:
        out.write("\n".join(bucket) + ("\n" if bucket else ""))
    print(f"[shard] shard_{sid}: {len(bucket)} frames")
PY

INFER_ARGS=(
  --require-geometry-cache
  --geometry-fallback filter_cg
  --use-geometry-cache
  --geometry-dir "$GEOMETRY_DIR"
  --out-dir "$OUT_DIR"
  --no-save-config
)

if [[ -n "$CONFIG_JSON" ]]; then
  INFER_ARGS+=(--config-json "$CONFIG_JSON")
elif [[ -n "$PRESET" ]]; then
  INFER_ARGS+=(--preset "$PRESET")
else
  echo "Set PRESET or CONFIG_JSON" >&2
  exit 1
fi

if [[ -n "$PER_SEQ_CONFIG" ]]; then
  INFER_ARGS+=(--per-seq-config "$PER_SEQ_CONFIG")
fi
if [[ -n "${GEOMETRY_SECONDARY_DIR:-}" ]]; then
  INFER_ARGS+=(--geometry-secondary-dir "$GEOMETRY_SECONDARY_DIR")
fi
if [[ -n "${ENH_HISTORY_DIR:-}" ]]; then
  INFER_ARGS+=(--enh-history-dir "$ENH_HISTORY_DIR")
fi
if [[ "${REFINE_NO_SKIP_EXISTING:-0}" == "1" ]]; then
  INFER_ARGS+=(--no-skip-existing)
fi

PIDS=()
for ((sid = 0; sid < NUM_SHARDS; sid++)); do
  shard_list="$SHARD_DIR/cg_shard_${sid}.txt"
  log="$LOGDIR/$(basename "$OUT_DIR")_shard${sid}.log"
  echo "[shard] cpu shard${sid} -> $log"
  (
    python "$ROOT/scripts/run_enh_refine_infer.py" \
      --cg-list "$shard_list" \
      "${INFER_ARGS[@]}" \
      > "$log" 2>&1
  ) &
  PIDS+=($!)
done

FAIL=0
for pid in "${PIDS[@]}"; do
  wait "$pid" || FAIL=1
done

if [[ "$FAIL" -ne 0 ]]; then
  echo "[shard] FAILED — see $LOGDIR/*_shard*.log" >&2
  exit 1
fi

MERGE_ARGS=()
for a in "${INFER_ARGS[@]}"; do
  [[ "$a" == "--no-save-config" ]] && continue
  [[ "$a" == "--no-skip-existing" ]] && continue
  MERGE_ARGS+=("$a")
done
# Merge pass: rebuild infer_meta.json only; never re-refine existing PLY.
python "$ROOT/scripts/run_enh_refine_infer.py" \
  --cg-list "$CG_LIST" \
  --out-dir "$OUT_DIR" \
  --skip-existing \
  "${MERGE_ARGS[@]}" \
  2>&1 | tail -3

echo "[shard] done -> $OUT_DIR"
