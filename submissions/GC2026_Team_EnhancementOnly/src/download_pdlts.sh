#!/usr/bin/env bash
set -euo pipefail
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SRC_DIR}/common.sh"
mkdir -p "${GC2026_ROOT}/code"
if [[ ! -d "${PDLTS_ROOT}/.git" ]]; then
  git clone https://github.com/yanbiao1/PD-LTS.git "${PDLTS_ROOT}"
fi
if [[ ! -f "${PDLTS_FINETUNE_CKPT}" ]]; then
  echo "Missing finetune ckpt: ${PDLTS_FINETUNE_CKPT}" >&2
  exit 1
fi
echo "[download_pdlts] finetune ckpt OK"
