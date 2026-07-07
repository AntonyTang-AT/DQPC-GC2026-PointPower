#!/usr/bin/env bash
# Quick smoke test on 2 frames.
# Prerequisite: pair lists generated, see README.
set -euo pipefail
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SRC_DIR}/common.sh"
SMOKE_FRAMES="${SMOKE_FRAMES:-2}"
OUT_DIR="${OUT_DIR:-${GC2026_ROOT}/output/submission_smoke_frame_gate_v2}"
VAL_CG="${GC2026_ROOT}/data/processed/val_cg_only_official_cgv2.txt"
if [[ ! -f "$VAL_CG" ]]; then
  echo "[run_smoke] Pair lists not found at $VAL_CG" >&2
  echo "[run_smoke] Run: bash ${SUBMISSION_ROOT}/data/generate_pair_lists.sh" >&2
  exit 1
fi
mkdir -p "$OUT_DIR"
head -n "$SMOKE_FRAMES" "$VAL_CG" > "$OUT_DIR/smoke_cg_list.txt"
export OUT_DIR CG_LIST="$OUT_DIR/smoke_cg_list.txt"
export GEOMETRY_DIR="${GEOMETRY_DIR:-$OUT_DIR/pdlts_geometry}"
export GEOMETRY_SECONDARY_DIR="${GEOMETRY_SECONDARY_DIR:-$OUT_DIR/superpc_geometry}"
export GATE_JSON="${SUBMISSION_ROOT}/config/gate_decision.json"
bash "${SRC_DIR}/run.sh"
echo "[run_smoke] DONE -> $OUT_DIR"
