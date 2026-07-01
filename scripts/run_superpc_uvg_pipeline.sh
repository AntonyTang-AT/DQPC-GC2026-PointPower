#!/usr/bin/env bash
# SuperPC UVG pipeline placeholder: upstream has no UVG fine-tune; run val565 infer instead.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="${SUPERPC_PIPE_ROOT:-$ROOT/output/superpc_uvg_pipeline}"
LOG="$BASE/logs/pipeline.log"
mkdir -p "$(dirname "$LOG")"

log() { echo "[superpc_uvg] $(date +%H:%M:%S) $*" | tee -a "$LOG"; }

wait_infer() {
  local out="${SUPERPC_OUT:-$BASE/val565}"
  local target=565
  log "wait infer $out"
  while true; do
    local n
    n=$(find "$out" -name '*.ply' 2>/dev/null | wc -l)
    log "  superpc infer ${n}/${target}"
    python3 - <<PY
import json, time, glob, os
base = "$BASE"
out = "$out"
n = len(glob.glob(out + "/*/*.ply"))
json.dump({"updated": time.strftime("%Y-%m-%d %H:%M:%S"), "phase": "superpc_infer", "infer_ply": n, "note": "no UVG finetune train code; using frozen kitti360_com.pth infer"}, open(base + "/pipeline_status.json", "w"), indent=2)
PY
    [[ "$n" -ge "$target" ]] && break
    pgrep -f "run_superpc_infer.py.*${out}" >/dev/null 2>&1 || break
    sleep 30
  done
}

stage_infer() {
  log "NOTE: SuperPC UVG fine-tune unavailable (upstream training not released)."
  log "Running val565 infer with gate ckpt (kitti360_com.pth, blend_cg vx=3.0)."
  bash "$ROOT/scripts/run_superpc_val565_quad.sh"
  wait_infer
  log "superpc infer done"
}

case "${1:-infer}" in
  infer) stage_infer ;;
  *) echo "Usage: $0 infer" >&2; exit 1 ;;
esac
