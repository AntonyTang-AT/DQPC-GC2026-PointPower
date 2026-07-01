#!/usr/bin/env bash
# Infer-only phase for P0/P1/P2 (no eval). Safe to run while eval runs separately.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRID="${GRID_ROOT:-$ROOT/output/enh_refine_p0_p1_p2}"
CG_LIST="$GRID/cg_list.txt"

source /root/miniconda3/etc/profile.d/conda.sh
conda activate superpc
export PYTHONPATH="$ROOT/scripts:${PYTHONPATH:-}"
export OPENBLAS_NUM_THREADS="${OPENBLAS_NUM_THREADS:-2}"
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-2}"

log() { echo "[infer_only] $(date +%H:%M:%S) $*"; }

run_infer() {
  local name="$1"
  shift
  local out="$GRID/$name"
  mkdir -p "$out"
  if [[ -f "$out/infer_meta.json" ]]; then
    log "skip (done) $name"
    return 0
  fi
  log "start $name"
  python "$ROOT/scripts/run_enh_refine_infer.py" \
    --cg-list "$CG_LIST" \
    --out-dir "$out" \
    "$@"
}

COMMON=(--require-geometry-cache --geometry-fallback filter_cg --use-geometry-cache)

log "configs"
python "$ROOT/scripts/build_per_sequence_snap_fill_templates.py" \
  --out-json "$GRID/per_seq_config.json"
test -f "$GRID/frame_decision/proxy_rules.json" || \
  python "$ROOT/scripts/build_per_frame_refine_decision.py" --out-dir "$GRID/frame_decision"

log "P0 per-seq"
rm -rf "$GRID/p0_perseq" "$GRID/p0_perseq_rollback"
run_infer p0_perseq \
  --preset pdlts_light_snap1_fill0.6 \
  --per-seq-config "$GRID/per_seq_config.json" \
  "${COMMON[@]}"

log "P0 per-seq + rollback proxy"
run_infer p0_perseq_rollback \
  --preset pdlts_light_snap1_fill0.6 \
  --per-seq-config "$GRID/per_seq_config.json" \
  --frame-proxy-json "$GRID/frame_decision/proxy_rules.json" \
  "${COMMON[@]}"

log "P1 post25 / adapt"
for preset in pdlts_light_snap1_fill0.6_post25 pdlts_light_snap1_adapt; do
  src="$ROOT/output/enh_refine_phase2/$preset"
  out="$GRID/$preset"
  if [[ -d "$src" && -f "$src/infer_meta.json" ]]; then
    log "link phase2 infer $preset"
    rm -rf "$out"
    mkdir -p "$out"
    cp -a "$src"/* "$out/"
  else
    run_infer "$preset" --preset "$preset" "${COMMON[@]}"
  fi
done

log "P1 heavy partial cache"
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
  --require-geometry-cache --geometry-fallback filter_cg \
  --use-geometry-cache --geometry-dir "$ROOT/output/pdlts_val565/heavy"

log "P2 density / bidir / combined"
for preset in pdlts_light_snap1_fill0.6_density pdlts_light_snap1_fill0.6_bidir pdlts_light_snap1_fill0.6_combined; do
  run_infer "$preset" --preset "$preset" "${COMMON[@]}"
done

log "DONE infer_only"
