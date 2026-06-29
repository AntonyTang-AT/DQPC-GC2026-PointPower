#!/usr/bin/env bash
set -euo pipefail
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SRC_DIR}/common.sh"

SMOKE_FRAMES="${SMOKE_FRAMES:-2}"
OUT_DIR="${OUT_DIR:-${GC2026_ROOT}/output/submission_smoke}"
VAL_CG="${GC2026_ROOT}/data/processed/val_cg_only_official_cgv2.txt"
mkdir -p "$OUT_DIR"
head -n "$SMOKE_FRAMES" "$VAL_CG" > "$OUT_DIR/smoke_cg_list.txt"
export OUT_DIR CG_LIST="$OUT_DIR/smoke_cg_list.txt"
export GEOMETRY_DIR="${GEOMETRY_DIR:-$OUT_DIR/pdlts_geometry}"
export GATE_JSON="${SUBMISSION_ROOT}/config/gate_decision.json"
export UVG_CG_VERSION="${UVG_CG_VERSION:-v2}"
bash "${SRC_DIR}/run.sh"
echo "[run_smoke] DONE frames=$SMOKE_FRAMES -> $OUT_DIR"
