#!/usr/bin/env bash
# Official validation smoke (565 frames): Stage1 N0 on TrumanShow + VictoryHeart + VirtualLife.
set -euo pipefail

GC2026_ROOT="${GC2026_ROOT:-/root/autodl-tmp/GC2026}"
SCRIPT_DIR="${GC2026_ROOT}/scripts"
PY="${PY:-python3.12}"
RECON_ROOT="${RECON_ROOT:-${GC2026_ROOT}/output/official_val_n0_v2_recon}"
TAG="${STAGE1_TAG:-N0_cwipc_official}"
STAGE1_JOBS="${STAGE1_JOBS:-3}"
VAL_SEQS=(TrumanShow VictoryHeart VirtualLife)
VAL_CG="${GC2026_ROOT}/data/processed/val_cg_only_official_cgv2.txt"

source "${SCRIPT_DIR}/env_setup.sh"
if [[ -f "${GC2026_ROOT}/output/cwipc_env.sh" ]]; then
  # shellcheck source=/dev/null
  source "${GC2026_ROOT}/output/cwipc_env.sh"
fi

if [[ ! -f "$VAL_CG" ]]; then
  "$PY" "${SCRIPT_DIR}/build_split_pairs.py"
fi

mkdir -p "$RECON_ROOT"
echo "[official_val_smoke] recon=$RECON_ROOT tag=$TAG"

run_seq() {
  local seq="$1"
  local seq_list="${GC2026_ROOT}/output/stage1_work/_cg_${seq}.txt"
  mkdir -p "${GC2026_ROOT}/output/stage1_work"
  grep "/${seq}/" "$VAL_CG" >"$seq_list"
  echo "[official_val_smoke] stage1 seq=$seq frames=$(wc -l < "$seq_list")"
  "$PY" "${SCRIPT_DIR}/rgbd_to_cg.py" \
    --cg-list "$seq_list" \
    --out-root "$RECON_ROOT" \
    --no-coord-corrections \
    --force \
    --backend cwipc \
    --cwipc-filter-profile official
}

export -f run_seq
export GC2026_ROOT SCRIPT_DIR PY RECON_ROOT VAL_CG
printf '%s\n' "${VAL_SEQS[@]}" | xargs -P "$STAGE1_JOBS" -I{} bash -c 'run_seq "$1"' _ {}

"$PY" <<PY
import os
cg_list = "${VAL_CG}"
out_root = "${RECON_ROOT}"
paths = []
for ln in open(cg_list):
    ref = ln.strip()
    if not ref:
        continue
    seq = ref.split("/UVG-CWI-DQPC/")[1].split("/")[0]
    out = os.path.join(out_root, seq, os.path.basename(ref))
    if os.path.isfile(out):
        paths.append(out)
lst = os.path.join(out_root, "reconstructed_cg_list.txt")
open(lst, "w").write("\\n".join(paths) + ("\\n" if paths else ""))
print(f"[official_val_smoke] list={len(paths)} frames")
PY

"$PY" "${SCRIPT_DIR}/eval_native_gate.py" \
  --recon-root "$RECON_ROOT" \
  --cg-list "$VAL_CG" \
  --out-json "${RECON_ROOT}/native_gate_official_val.json"

echo "[official_val_smoke] DONE ply=$(find "$RECON_ROOT" -name '*.ply' | wc -l)"
