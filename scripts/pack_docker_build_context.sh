#!/usr/bin/env bash
# Pack Docker build context for organizer / senior to build on a privileged host.
set -euo pipefail

GC2026_ROOT="${GC2026_ROOT:-/root/autodl-tmp/GC2026}"
OUT="${GC2026_ROOT}/output/GC2026_docker_build_context.tar.gz"

cd "$GC2026_ROOT"
cp -f submissions/GC2026_Team/requirements.txt requirements.txt

tar -czf "$OUT" \
  Dockerfile .dockerignore requirements.txt \
  scripts/ code/SuperPC/ \
  submissions/GC2026_Team/src/ \
  models/superpc_pretrained/ \
  data/processed/ \
  data/raw/UVG-CWI-DQPC.json \
  docker/ \
  output/docker_build_instructions.txt

ls -lh "$OUT"
md5sum "$OUT"
echo "[pack_docker] done -> $OUT"
