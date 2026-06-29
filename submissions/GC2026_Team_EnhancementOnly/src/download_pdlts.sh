#!/usr/bin/env bash
set -euo pipefail
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SRC_DIR}/common.sh"
mkdir -p "${GC2026_ROOT}/code"
if [[ ! -d "${PDLTS_ROOT}/.git" ]]; then
  git clone https://github.com/yanbiao1/PD-LTS.git "${PDLTS_ROOT}"
fi
CKPT="${PDLTS_ROOT}/product/ckpt/Denoiseflow-light-FBM.ckpt"
if [[ ! -f "$CKPT" ]]; then
  echo "Checkpoint missing: $CKPT"
  echo "Download from PD-LTS release / Google Drive (see PD-LTS README) into product/ckpt/"
  exit 1
fi
echo "[download_pdlts] OK $CKPT"
