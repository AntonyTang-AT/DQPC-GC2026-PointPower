#!/usr/bin/env bash
# Verify GC2026_Team_EnhancementOnly against UVG-CWI/submissions requirements + runtime smoke.
set -euo pipefail

GC2026_ROOT="${GC2026_ROOT:-/root/autodl-tmp/GC2026}"
SUB="${SUB:-${GC2026_ROOT}/submissions/GC2026_Team_EnhancementOnly}"
LOG="${LOG:-${GC2026_ROOT}/output/meeting_delivery/submission_verify.log}"
SMOKE_OUT="${SMOKE_OUT:-${GC2026_ROOT}/output/submission_smoke_verify}"
SMOKE_FRAMES="${SMOKE_FRAMES:-2}"
RUN_SMOKE="${RUN_SMOKE:-1}"

mkdir -p "$(dirname "$LOG")" "$SMOKE_OUT"
exec > >(tee -a "$LOG") 2>&1

echo "[verify] START $(date -Is) SUB=$SUB"

FAIL=0
ok() { echo "[verify] OK  $*"; }
warn() { echo "[verify] WARN $*"; }
bad() { echo "[verify] FAIL $*"; FAIL=1; }

# --- 1) Official directory layout (UVG-CWI/submissions README) ---
for req in README.md src requirements.txt; do
  [[ -f "$SUB/$req" || -d "$SUB/$req" ]] && ok "exists $req" || bad "missing required $req"
done
[[ -f "$SUB/src/run.sh" ]] && ok "entrypoint src/run.sh" || bad "missing src/run.sh"
[[ ! -d "$SUB/data/raw" ]] && ok "no bundled dataset" || warn "data/raw present (should not commit dataset)"

# --- 2) README required sections ---
README="$SUB/README.md"
for section in "Team Name" "Team Members" "Algorithm Name" "Algorithm Description" "Processing Track" "How to Run" "Hardware" "Runtime"; do
  if grep -qi "$section" "$README" 2>/dev/null; then
    ok "README has: $section"
  else
    bad "README missing section: $section"
  fi
done
if grep -qi "Enhancement Only" "$README"; then ok "track Enhancement Only"; else bad "Processing Track not Enhancement Only"; fi

# --- 3) Shell / Python syntax ---
while IFS= read -r -d '' f; do
  bash -n "$f" && ok "bash -n $(basename "$f")" || bad "bash syntax $f"
done < <(find "$SUB/src" -name '*.sh' -print0)

while IFS= read -r -d '' f; do
  python3 -m py_compile "$f" && ok "py_compile $(basename "$f")" || bad "python syntax $f"
done < <(find "$SUB/src" -name '*.py' -print0)

# --- 4) Config / gate ---
[[ -f "$SUB/config/gate_decision.json" ]] && ok "gate_decision.json" || bad "missing config/gate_decision.json"
[[ -f "$SUB/config/gate_config.json" ]] && ok "gate_config.json" || bad "missing gate_config.json"

# --- 5) Dependencies on organizer machine ---
export GC2026_ROOT
export SUBMISSION_ROOT="$SUB"
# shellcheck source=/dev/null
source "$SUB/src/common.sh"
# Use project conda env for SuperPC extensions when available
if [[ -f "${GC2026_ROOT}/scripts/env_setup.sh" ]]; then
  # shellcheck source=/dev/null
  source "${GC2026_ROOT}/scripts/env_setup.sh"
  export PYTHON="${PYTHON:-python}"
fi

PDLTS_ROOT="${PDLTS_ROOT:-${GC2026_ROOT}/code/PD-LTS}"
[[ -d "$PDLTS_ROOT" ]] && ok "PD-LTS clone $PDLTS_ROOT" || bad "missing code/PD-LTS (organizer must clone)"
CKPT="${PDLTS_ROOT}/product/ckpt/Denoiseflow-light-FBM.ckpt"
[[ -f "$CKPT" ]] && ok "checkpoint Denoiseflow-light-FBM.ckpt" || bad "missing PD-LTS light checkpoint"

if [[ -f "$CKPT" ]] && [[ -f "$SUB/src/verify_pdlts_ckpt.py" ]]; then
  if "$PYTHON" "$SUB/src/verify_pdlts_ckpt.py" --ckpt-path "$CKPT" 2>&1 | tail -3; then
    ok "verify_pdlts_ckpt"
  else
    bad "verify_pdlts_ckpt failed"
  fi
fi

GATE_NAME=$(python3 -c "import json; g=json.load(open('$SUB/config/gate_decision.json')); print(g.get('production_config',g.get('best_config',{})).get('name',''))" 2>/dev/null || echo "")
if [[ "$GATE_NAME" == *"pdlts_light_snap1_fill0.6_density"* ]]; then
  ok "gate preset pdlts_density"
else
  bad "gate preset expected pdlts_light_snap1_fill0.6_density got: $GATE_NAME"
fi

# --- 6) GPU optional check ---
if "$PYTHON" -c "import torch; assert torch.cuda.is_available()" 2>/dev/null; then
  ok "CUDA available"
else
  warn "CUDA not available — skip infer smoke"
  RUN_SMOKE=0
fi

# --- 7) 2-frame inference smoke from submission entrypoint ---
if [[ "$RUN_SMOKE" == "1" ]]; then
  echo "[verify] smoke infer $SMOKE_FRAMES frames -> $SMOKE_OUT"
  rm -rf "$SMOKE_OUT"
  mkdir -p "$SMOKE_OUT"
  VAL_CG="${GC2026_ROOT}/data/processed/val_cg_only_official_cgv2.txt"
  [[ -f "$VAL_CG" ]] || bad "missing val CG list"
  head -n "$SMOKE_FRAMES" "$VAL_CG" > "$SMOKE_OUT/smoke_cg_list.txt"
  export OUT_DIR="$SMOKE_OUT"
  export CG_LIST="$SMOKE_OUT/smoke_cg_list.txt"
  export GATE_JSON="$SUB/config/gate_decision.json"
  export UVG_CG_VERSION=v2
  export SUBMISSION_SKIP_CONDA=0
  export GEOMETRY_DIR="${SMOKE_OUT}/pdlts_geometry"
  cd "$SUB"
  if bash src/run.sh; then
    echo "[verify] waiting for PD-LTS workers (max 300s)..."
    for _ in $(seq 1 150); do
      if pgrep -f "run_pdlts_infer.py.*${SMOKE_OUT}" >/dev/null 2>&1; then
        sleep 2
      else
        break
      fi
    done
    sleep 2
  nply=$(find "$SMOKE_OUT" -name '*.ply' | wc -l)
    if [[ "$nply" -ge "$SMOKE_FRAMES" ]]; then
      ok "smoke infer produced $nply ply (expected >= $SMOKE_FRAMES)"
    else
      bad "smoke infer only $nply ply"
    fi
  else
    bad "src/run.sh failed"
  fi
fi

# --- 8) Write report json ---
REPORT="${GC2026_ROOT}/output/meeting_delivery/submission_verify_report.json"
python3 - <<PY
import json, os, datetime
print(json.dumps({
  "checked_at": datetime.datetime.utcnow().isoformat() + "Z",
  "package": "$SUB",
  "log": "$LOG",
  "smoke_out": "$SMOKE_OUT",
  "exit_fail": $FAIL,
  "official_ref": "https://github.com/UVG-CWI/submissions",
}, indent=2))
open("$REPORT", "w").write(json.dumps({
  "checked_at": datetime.datetime.utcnow().isoformat() + "Z",
  "package": "$SUB",
  "passed": $FAIL == 0,
  "log": "$LOG",
}, indent=2))
PY

echo "[verify] END exit=$FAIL"
exit "$FAIL"
