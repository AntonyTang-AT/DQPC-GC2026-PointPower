#!/usr/bin/env bash
# Full Enhancement Only: 2155 frames PD-LTS light + pdlts_density refine.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/env_setup.sh"

CG_LIST="${CG_LIST:-${ROOT}/data/processed/all_cg_only_cgv2.txt}"
GEOMETRY_DIR="${GEOMETRY_DIR:-${ROOT}/output/pdlts_geometry/light}"
OUT_DIR="${OUT_DIR:-${ROOT}/output/submission_candidate_pdlts_density}"
GATE_JSON="${GATE_JSON:-${ROOT}/output/enh_refine_p0_p1_p2/gate_decision.json}"
LOG="${LOG:-${ROOT}/output/pdlts_full_submission.log}"

exec > >(tee -a "$LOG") 2>&1
echo "[pdlts_full] START $(date -Is)"
echo "[pdlts_full] CG_LIST=$CG_LIST GEOMETRY=$GEOMETRY_DIR OUT=$OUT_DIR"

export CG_LIST GEOMETRY_DIR OUT_DIR GATE_JSON
export GC2026_ROOT="$ROOT"
export SUBMISSION_ROOT="${ROOT}/submissions/GC2026_Team_EnhancementOnly"
export UVG_CG_VERSION=v2

bash "${SUBMISSION_ROOT}/src/run.sh"

echo "[pdlts_full] post manifest"
bash "${SUBMISSION_ROOT}/src/post_submission_candidate.sh"

echo "[pdlts_full] DONE $(date -Is)"
