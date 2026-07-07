#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBMISSION_ROOT="$(cd "${SRC_DIR}/.." && pwd)"

if [[ -z "${GC2026_ROOT:-}" ]]; then
  echo "[common.sh] FATAL: GC2026_ROOT is not set." >&2
  echo "[common.sh] Set your dataset workspace root (relative paths in docs are under this directory):" >&2
  echo "  export GC2026_ROOT=./workspace" >&2
  exit 1
fi
GC2026_ROOT="$(cd "$GC2026_ROOT" && pwd)"
export GC2026_ROOT SUBMISSION_ROOT SRC_DIR
export PDLTS_ROOT="${PDLTS_ROOT:-${GC2026_ROOT}/code/PD-LTS}"
export SUPERPC_ROOT="${SUPERPC_ROOT:-${GC2026_ROOT}/code/SuperPC}"
export SCRIPT_DIR="${SRC_DIR}"
export PY="${PY:-python3}"

# PD-LTS inference ckpt: prefer newest self-trained run, else bundled UVG fine-tune.
# Override anytime: export PDLTS_FINETUNE_CKPT=path/to.ckpt
resolve_pdlts_finetune_ckpt() {
  local bundled="${SUBMISSION_ROOT}/models/DenoiseFlow-light-UVG-finetune.ckpt"
  local latest=""
  latest=$(ls -t "${GC2026_ROOT}/output/pdlts_finetune_uvg"/run_*/DenoiseFlow-light-UVG-finetune.ckpt 2>/dev/null | head -1 || true)
  if [[ -z "$latest" && -f "${GC2026_ROOT}/output/pdlts_finetune_uvg/smoke/DenoiseFlow-light-UVG-finetune.ckpt" ]]; then
    latest="${GC2026_ROOT}/output/pdlts_finetune_uvg/smoke/DenoiseFlow-light-UVG-finetune.ckpt"
  fi
  if [[ -n "$latest" ]]; then
    echo "$latest"
  else
    echo "$bundled"
  fi
}

if [[ -z "${PDLTS_FINETUNE_CKPT:-}" ]]; then
  PDLTS_FINETUNE_CKPT="$(resolve_pdlts_finetune_ckpt)"
fi
export PDLTS_FINETUNE_CKPT
export SUPERPC_CKPT="${SUPERPC_CKPT:-${SUBMISSION_ROOT}/models/kitti360_com.pth}"

if [[ -f "${SRC_DIR}/env_setup.sh" ]] && [[ "${SUBMISSION_SKIP_CONDA:-0}" != "1" ]]; then
  if [[ -f "${HOME}/miniconda3/etc/profile.d/conda.sh" ]]; then
    source "${HOME}/miniconda3/etc/profile.d/conda.sh"
    conda activate superpc 2>/dev/null || true
    export PATH="${CONDA_PREFIX:-}/bin:${PATH}"
    export PYTHON="${CONDA_PREFIX:-}/bin/python3.9"
  fi
fi

export PYTHON="${PYTHON:-python3}"
export UVG_VAL_PAIRS_FILE="${UVG_VAL_PAIRS_FILE:-${GC2026_ROOT}/data/processed/val_pairs_official_cgv2.txt}"
