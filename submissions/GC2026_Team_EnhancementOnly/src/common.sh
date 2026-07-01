#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBMISSION_ROOT="$(cd "${SRC_DIR}/.." && pwd)"

if [[ -z "${GC2026_ROOT:-}" ]]; then
  if [[ -d "${SUBMISSION_ROOT}/../data" ]]; then
    GC2026_ROOT="$(cd "${SUBMISSION_ROOT}/.." && pwd)"
  elif [[ -d "${SUBMISSION_ROOT}/../../data" ]]; then
    GC2026_ROOT="$(cd "${SUBMISSION_ROOT}/../.." && pwd)"
  else
    GC2026_ROOT="$(cd "${SUBMISSION_ROOT}/.." && pwd)"
  fi
fi
export GC2026_ROOT SUBMISSION_ROOT SRC_DIR
export PDLTS_ROOT="${PDLTS_ROOT:-${GC2026_ROOT}/code/PD-LTS}"
export SUPERPC_ROOT="${SUPERPC_ROOT:-${GC2026_ROOT}/code/SuperPC}"
export SCRIPT_DIR="${SRC_DIR}"
export PY="${PY:-python3}"
export PDLTS_FINETUNE_CKPT="${PDLTS_FINETUNE_CKPT:-${SUBMISSION_ROOT}/models/DenoiseFlow-light-UVG-finetune.ckpt}"
export SUPERPC_CKPT="${SUPERPC_CKPT:-${GC2026_ROOT}/models/superpc_pretrained/kitti360_com.pth}"

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
