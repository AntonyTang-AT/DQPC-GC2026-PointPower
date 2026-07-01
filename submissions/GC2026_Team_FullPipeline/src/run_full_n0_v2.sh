#!/usr/bin/env bash
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SRC_DIR}/common.sh"
SCRIPT_DIR="${SRC_DIR}"
# Full Pipeline N0 v2 (GC2026 compliant): cwipc Stage1 -> SuperPC -> post.
set -euo pipefail

GC2026_ROOT="${GC2026_ROOT:-${GC2026_ROOT}}"
SCRIPT_DIR="${SCRIPT_DIR}"
LOG="${GC2026_ROOT}/output/full_n0_v2.log"
STATE="${GC2026_ROOT}/output/full_n0_v2.state"
LOCK="${GC2026_ROOT}/output/full_n0_v2.lock"
PY="${PY:-python3.12}"
TAG="${STAGE1_TAG:-N0_cwipc_official}"
STAGE1_JOBS="${STAGE1_JOBS:-6}"
TARGET_PLY=2155
RECON_ROOT="${RECON_ROOT:-${GC2026_ROOT}/output/full_pipeline_n0_v2_cg}"
ENH_ROOT="${ENH_ROOT:-${GC2026_ROOT}/output/full_pipeline_n0_v2_candidate}"
OFFICIAL_VAL_RECON="${OFFICIAL_VAL_RECON:-${GC2026_ROOT}/output/official_val_n0_v2_recon}"
RECON_ENH_CONFIG="${RECON_ENH_CONFIG:-${GC2026_ROOT}/output/full_n0_v2_recon_enh_config.json}"
VAL_PAIRS="${UVG_VAL_PAIRS_FILE:-${GC2026_ROOT}/data/processed/val_pairs_official_cgv2.txt}"
VAL_CG_LIST="${GC2026_ROOT}/data/processed/val_cg_only_official_cgv2.txt"

exec > >(tee -a "$LOG") 2>&1

progress() {
  local phase="$1"
  local recon enh
  mkdir -p "$RECON_ROOT" "$ENH_ROOT"
  recon=$(find "$RECON_ROOT" -name '*.ply' 2>/dev/null | wc -l | tr -d ' ') || recon=0
  enh=$(find "$ENH_ROOT" -name '*.ply' 2>/dev/null | wc -l | tr -d ' ') || enh=0
  echo "[full_n0_v2] PROGRESS phase=${phase} recon_ply=${recon}/${TARGET_PLY} enh_ply=${enh}/${TARGET_PLY} $(date +%H:%M:%S)"
}

mark() {
  echo "$1=$(date -Is)" >>"$STATE"
  echo "[full_n0_v2] $1"
}

state_has() {
  grep -qE "^${1}=" "$STATE" 2>/dev/null
}

reorganize_enh() {
  local root="$1"
  "$PY" <<PY
import glob, os, shutil
root = "${root}"
moved = 0
for sub in ("output", "GC2026"):
    flat = os.path.join(root, sub)
    if not os.path.isdir(flat):
        continue
    for ply in glob.glob(os.path.join(flat, "*.ply")):
        base = os.path.basename(ply)
        seq = base.split("_UVG")[0]
        dst_dir = os.path.join(root, seq)
        os.makedirs(dst_dir, exist_ok=True)
        dst = os.path.join(dst_dir, base)
        if not os.path.isfile(dst):
            shutil.copy2(ply, dst)
            moved += 1
for ply in glob.glob(os.path.join(root, "*_UVG-CWI-DQPC_ENH_*.ply")):
    base = os.path.basename(ply)
    seq = base.split("_UVG")[0]
    dst_dir = os.path.join(root, seq)
    os.makedirs(dst_dir, exist_ok=True)
    dst = os.path.join(dst_dir, base)
    if not os.path.isfile(dst):
        shutil.move(ply, dst)
        moved += 1
print(f"[full_n0_v2] reorganized {moved} ENH into per-sequence dirs")
PY
}

count_ply() {
  find "$1" -name '*.ply' 2>/dev/null | wc -l | tr -d ' '
}

STOP_AFTER_PHASE="${STOP_AFTER_PHASE:-3}"

main() {
  mkdir -p "${GC2026_ROOT}/output" "${GC2026_ROOT}/data/processed"
  touch "$STATE"
  exec 9>"$LOCK"
  if ! flock -n 9; then
    echo "[full_n0_v2] another runner active — exit"
    exit 0
  fi

  echo "=============================================="
  echo "[full_n0_v2] START $(date -Is)"
  echo "[full_n0_v2] TAG=$TAG STAGE1_JOBS=$STAGE1_JOBS"
  echo "[full_n0_v2] recon=$RECON_ROOT enh=$ENH_ROOT"
  echo "[full_n0_v2] official val pairs=$VAL_PAIRS"
  echo "=============================================="

  if [[ ! -f "$VAL_PAIRS" ]]; then
    "$PY" "${SCRIPT_DIR}/build_split_pairs.py"
  fi

  source "${SCRIPT_DIR}/env_setup.sh"
  if [[ -f "${GC2026_ROOT}/output/cwipc_env.sh" ]]; then
    # shellcheck source=/dev/null
    source "${GC2026_ROOT}/output/cwipc_env.sh"
  fi

  if ! state_has "phase0=done"; then
    mark "phase0_begin"
    df -h /root/autodl-tmp | tail -1
    nvidia-smi -L || true
    mark "phase0=done"
  fi

  recon_n=$(count_ply "$RECON_ROOT")
  if ! state_has "phase1=done"; then
    if [[ "$recon_n" -ge 2150 ]]; then
      echo "[full_n0_v2] skip Stage1 — recon already complete ($recon_n ply)"
      mark "phase1=done"
    else
      mark "phase1_begin"
      progress "stage1_start"
      VAL_MERGE_ROOT="$OFFICIAL_VAL_RECON" \
        VAL_SEQS="TrumanShow,VictoryHeart,VirtualLife" \
        VAL_SEQ_TAG_OVERRIDES="VictoryHeart:N0_cwipc_official,TrumanShow:N0_cwipc_official,VirtualLife:N0_cwipc_official" \
        OUT_ROOT="$RECON_ROOT" TAG="$TAG" \
        STAGE1_JOBS="$STAGE1_JOBS" \
        BASELINE_RECON="" \
        bash "${SCRIPT_DIR}/run_stage1_native_parallel.sh"
      progress "stage1_done"
      if [[ -f "$VAL_CG_LIST" ]]; then
        "$PY" "${SCRIPT_DIR}/eval_native_gate.py" \
          --recon-root "$RECON_ROOT" \
          --cg-list "$VAL_CG_LIST" \
          --out-json "${RECON_ROOT}/native_gate.json" || true
      fi
      mark "phase1=done"
    fi
  fi

  if ! state_has "phase2=done"; then
    enh_n=$(count_ply "$ENH_ROOT")
    if [[ "$enh_n" -ge 2150 ]]; then
      echo "[full_n0_v2] skip SuperPC — ENH already complete ($enh_n ply)"
      mark "phase2=done"
    else
      mark "phase2_begin"
      RECON_LIST="${RECON_ROOT}/reconstructed_cg_list.txt"
      COMPARE_JSON="${GC2026_ROOT}/output/full_n0_v2_compare.json"
      if [[ -f "$RECON_LIST" && -f "$VAL_PAIRS" ]]; then
        "$PY" "${SCRIPT_DIR}/compare_reconstructed_cg.py" \
          --recon-root "$RECON_ROOT" \
          --pairs-file "$VAL_PAIRS" \
          --official-version v2 --max-samples 80 --n-samples 5000 --device cpu \
          --out-json "$COMPARE_JSON" || true
        if [[ -f "$COMPARE_JSON" ]]; then
          "$PY" "${SCRIPT_DIR}/build_recon_enh_config.py" \
            --compare-json "$COMPARE_JSON" \
            --out-json "$RECON_ENH_CONFIG" || true
        fi
      fi

      rm -rf "$ENH_ROOT"
      mkdir -p "$ENH_ROOT"
      export CG_LIST="$RECON_LIST"
      export OUT_DIR="$ENH_ROOT"
      export CKPT="${GC2026_ROOT}/models/superpc_pretrained/kitti360_com.pth"
      export OUTPUT_MODE=blend_cg
      export BLEND_VOXEL_MM=3.0
      export ENH_ADAPTIVE_BLEND=1
      cfg="$RECON_ENH_CONFIG"
      [[ -f "$cfg" ]] && export ENH_PER_SEQ_CONFIG="$cfg"
      bash "${SCRIPT_DIR}/run_dual_gpu_infer.sh"

      for ((i = 0; i < 180; i++)); do
        if ! pgrep -f "run_superpc_infer.py.*--out-dir ${ENH_ROOT}" >/dev/null 2>&1; then
          break
        fi
        progress "superpc"
        sleep 20
      done
      reorganize_enh "$ENH_ROOT"
      mark "phase2=done"
    fi
    if [[ "$STOP_AFTER_PHASE" -eq 2 ]]; then
      progress "phase2_complete"
      echo "[full_n0_v2] STOP_AFTER_PHASE=2"
      exit 0
    fi
  fi

  if ! state_has "phase3=done"; then
    mark "phase3_begin"
    reorganize_enh "$ENH_ROOT"
    RECON_ROOT="$RECON_ROOT" OUT_DIR="$ENH_ROOT" STAGE1_TAG="$TAG" \
      PACK_TAR="${PACK_TAR:-0}" bash "${SCRIPT_DIR}/post_full_pipeline.sh"
    if [[ -f "$VAL_CG_LIST" ]]; then
      "$PY" "${SCRIPT_DIR}/eval_native_gate.py" \
        --recon-root "$RECON_ROOT" \
        --enh-root "$ENH_ROOT" \
        --cg-list "$VAL_CG_LIST" \
        --out-json "${ENH_ROOT}/native_gate_enh.json" || true
    fi
    PLY=$(count_ply "$ENH_ROOT")
    progress "complete"
    echo "[full_n0_v2] FINAL enh_ply=$PLY"
    mark "phase3=done"
  fi

  echo "[full_n0_v2] END $(date -Is)"
}

main "$@"
