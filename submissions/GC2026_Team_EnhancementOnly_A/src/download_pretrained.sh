#!/usr/bin/env bash
set -euo pipefail
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SRC_DIR}/common.sh"
mkdir -p "${GC2026_ROOT}/code" "${GC2026_ROOT}/models/superpc_pretrained"
if [[ ! -d "${SUPERPC_ROOT}/.git" ]]; then
  git clone https://github.com/sair-lab/SuperPC "${SUPERPC_ROOT}"
fi
CKPT="${SUPERPC_CKPT}"
if [[ ! -f "$CKPT" ]]; then
  echo "SuperPC checkpoint missing: $CKPT"
  echo "Run scripts/download_pretrained.sh from GC2026 workspace or place kitti360_com.pth manually."
  exit 1
fi
echo "[download_pretrained] OK $CKPT"
