#!/usr/bin/env bash
set -euo pipefail
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SRC_DIR}/common.sh"

export RECON_ROOT="${RECON_ROOT:-${GC2026_ROOT}/output/full_pipeline_n0_v2_cg}"
export ENH_ROOT="${ENH_ROOT:-${GC2026_ROOT}/output/full_pipeline_n0_v2_candidate}"
export STAGE1_TAG="${STAGE1_TAG:-N0_cwipc_official}"
export UVG_VAL_PAIRS_FILE="${UVG_VAL_PAIRS_FILE:-${GC2026_ROOT}/data/processed/val_pairs_official_cgv2.txt}"

bash "${SRC_DIR}/run_full_n0_v2.sh"
