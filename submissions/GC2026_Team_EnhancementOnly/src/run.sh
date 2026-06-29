#!/usr/bin/env bash
# Enhancement Only: official CG -> PD-LTS light -> snap/fill density refine.
set -euo pipefail
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SRC_DIR}/common.sh"

export OUT_DIR="${OUT_DIR:-${GC2026_ROOT}/output/submission_candidate_pdlts_density}"
export GATE_JSON="${GATE_JSON:-${SUBMISSION_ROOT}/config/gate_decision.json}"
export GEOMETRY_DIR="${GEOMETRY_DIR:-${GC2026_ROOT}/output/pdlts_geometry/light}"
export UVG_CG_VERSION="${UVG_CG_VERSION:-v2}"
export SKIP_PDLTS="${SKIP_PDLTS:-0}"

if [[ -z "${CG_LIST:-}" ]]; then
  if [[ -f "${GC2026_ROOT}/data/processed/all_cg_only_cgv2.txt" ]]; then
    export CG_LIST="${GC2026_ROOT}/data/processed/all_cg_only_cgv2.txt"
  else
    export CG_LIST="${GC2026_ROOT}/data/processed/all_cg_only.txt"
  fi
fi

"${SRC_DIR}/download_pdlts.sh"

if [[ "$SKIP_PDLTS" != "1" ]]; then
  echo "[run.sh] Stage1 PD-LTS geometry -> $GEOMETRY_DIR"
  bash "${SRC_DIR}/run_dual_gpu_pdlts.sh"
fi

echo "[run.sh] Stage2 refine (pdlts_light_snap1_fill0.6_density) -> $OUT_DIR"
"$PYTHON" "${SRC_DIR}/run_enh_refine_infer.py" \
  --cg-list "$CG_LIST" \
  --out-dir "$OUT_DIR" \
  --refine-config "$GATE_JSON" \
  --geometry-dir "$GEOMETRY_DIR" \
  --use-geometry-cache \
  --require-geometry-cache

echo "[run.sh] DONE -> $OUT_DIR"
