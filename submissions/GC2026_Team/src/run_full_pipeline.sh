#!/usr/bin/env bash
# Full Pipeline: RGBD/bag -> reconstructed CG -> SuperPC -> ENH
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export OUT_DIR="${OUT_DIR:-$ROOT/output/full_pipeline_n0_v2_candidate}"
export RECON_ROOT="${RECON_ROOT:-$ROOT/output/full_pipeline_n0_v2_cg}"
bash "$ROOT/scripts/run_full_n0_v2.sh"
