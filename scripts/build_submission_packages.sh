#!/usr/bin/env bash
# Build two UVG-official submission packages: Enhancement Only + Full Pipeline.
set -euo pipefail

GC2026_ROOT="${GC2026_ROOT:-/root/autodl-tmp/GC2026}"
SCRIPT_DIR="${GC2026_ROOT}/scripts"
SUB_COMMON="${SCRIPT_DIR}/submission_src"
OUT_BASE="${GC2026_ROOT}/output"
GATE_JSON="${GC2026_ROOT}/output/val_grid/gate_decision.json"
PER_SEQ="${GC2026_ROOT}/output/enhancement_eval/per_sequence_enh_config.json"
RECON_CFG="${GC2026_ROOT}/output/enhancement_eval/recon_enh_config.json"

ENH_NAME="GC2026_Team_EnhancementOnly"
FULL_NAME="GC2026_Team_FullPipeline"
ENH_DIR="${GC2026_ROOT}/submissions/${ENH_NAME}"
FULL_DIR="${GC2026_ROOT}/submissions/${FULL_NAME}"

copy_scripts() {
  local dest_src="$1"
  shift
  mkdir -p "$dest_src"
  cp -f "${SUB_COMMON}/common.sh" "$dest_src/"
  for f in "$@"; do
    cp -f "${SCRIPT_DIR}/${f}" "$dest_src/"
  done
  chmod +x "$dest_src"/*.sh 2>/dev/null || true
}

patch_scripts() {
  local dest_src="$1"
  find "$dest_src" -name '*.sh' -print0 | while IFS= read -r -d '' f; do
    sed -i \
      -e 's|/root/autodl-tmp/GC2026|${GC2026_ROOT}|g' \
      -e 's|\${GC2026_ROOT}/scripts|\${SCRIPT_DIR}|g' \
      -e 's|\$GC2026_ROOT/scripts|\$SCRIPT_DIR|g' \
      "$f" 2>/dev/null || true
  done
}

inject_common_header() {
  local f="$1"
  local tmp
  tmp="$(mktemp)"
  {
    echo '#!/usr/bin/env bash'
    echo 'SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"'
    echo 'source "${SRC_DIR}/common.sh"'
    echo 'SCRIPT_DIR="${SRC_DIR}"'
    tail -n +2 "$f"
  } > "$tmp"
  mv "$tmp" "$f"
  chmod +x "$f"
}

write_env_setup() {
  local dest_src="$1"
  cat > "${dest_src}/env_setup.sh" <<'EOF'
#!/usr/bin/env bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
EOF
  chmod +x "${dest_src}/env_setup.sh"
}

write_gate_config() {
  local dest="$1"
  mkdir -p "${dest}/config"
  if [[ -f "$GATE_JSON" ]]; then
    python3 -c "
import json
g=json.load(open('$GATE_JSON'))
json.dump(g.get('best_config', g), open('${dest}/config/gate_config.json','w'), indent=2)
"
    cp -f "$GATE_JSON" "${dest}/config/gate_decision.json"
  fi
  [[ -f "$PER_SEQ" ]] && cp -f "$PER_SEQ" "${dest}/config/per_sequence_enh_config.json"
  [[ -f "$RECON_CFG" ]] && cp -f "$RECON_CFG" "${dest}/config/recon_enh_config.json"
}

write_requirements() {
  local dest="$1"
  cat > "${dest}/requirements.txt" <<'EOF'
torch>=2.0
numpy
scipy
open3d
plyfile
tqdm
transformers
accelerate
Pillow
gdown
EOF
}

write_setup_md() {
  local dest="$1"
  cat > "${dest}/SETUP.md" <<'EOF'
# Environment setup (organizers / reproducers)

## 1. Workspace layout

```text
/workspace/                    ← export GC2026_ROOT=/workspace
  code/SuperPC/                ← git clone https://github.com/sair-lab/SuperPC
  models/superpc_pretrained/   ← bash src/download_pretrained.sh
  data/raw/UVG-CWI-DQPC/       ← official dataset (CG / bag / HE)
  data/processed/              ← pair lists (included in Full package config/)
  submissions/GC2026_Team_*/ ← this package
```

## 2. Dependencies

```bash
conda create -n superpc python=3.9 -y && conda activate superpc
pip install -r requirements.txt
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu128  # adjust CUDA
```

## 3. SuperPC + weights

```bash
export GC2026_ROOT=/path/to/workspace
git clone https://github.com/sair-lab/SuperPC "$GC2026_ROOT/code/SuperPC"
bash src/download_pretrained.sh
```

Primary checkpoint: **kitti360_com.pth** (see `config/gate_config.json`).
EOF
}

write_enh_readme() {
  cat > "${ENH_DIR}/README.md" <<EOF
# GC2026 Team — Enhancement Only (SuperPC)

## Team Name
GC2026 Team

## Team Members
- *(Update before PR)* Member 1 — Affiliation
- *(Update before PR)* Member 2 — Affiliation

## Algorithm Name
SuperPC blend_cg (kitti360_com.pth, voxel 3.0 mm)

## Algorithm Description
Official consumer-grade CG PLY (v2) → SuperPC diffusion enhancement with \`blend_cg\` merging.
Per-sequence config when available. Trained weights: kitti360_com.pth.

## Processing Track
**Enhancement Only** (input: official CG \`.ply\`)

## How to Run

See [SETUP.md](SETUP.md) for SuperPC clone and checkpoint download.

\`\`\`bash
export GC2026_ROOT=/path/to/workspace   # contains data/, models/, code/
cd submissions/GC2026_Team_EnhancementOnly
conda activate superpc
bash src/run.sh
\`\`\`

Outputs: \`\$GC2026_ROOT/output/submission_candidate/\` (2155 ENH PLY + manifest.json)

Optional post-eval: \`bash src/post_submission_candidate.sh\`

## Hardware / Environment
- 2× NVIDIA RTX 5090 (training/dev); inference uses dual-GPU sharding when available
- Ubuntu 22.04, Python 3.9, PyTorch 2.x + CUDA 12.x
- Coordinate system: consumer-grade capture coordinates (mm), same as input CG

## Runtime
See generated \`output/submission_candidate/runtime.log\` after run.
Reference (our dev machine, 2155 frames): Stage2 SuperPC ~hours on 2× GPU.

## Selected config
See \`config/gate_config.json\` (blend_cg, voxel 3.0 mm, kitti360_com.pth).

## Official val565 result (local cd_l1, Jun 2026)
- ENH vs HE mean: **48.5 mm**
- Improvement vs official CG: **+2.8 mm**
EOF
}

write_full_readme() {
  cat > "${FULL_DIR}/README.md" <<EOF
# GC2026 Team — Full Pipeline (N0 cwipc + SuperPC)

## Team Name
GC2026 Team

## Team Members
- *(Update before PR)* Member 1 — Affiliation
- *(Update before PR)* Member 2 — Affiliation

## Algorithm Name
N0 cwipc-native Stage1 + SuperPC blend_cg

## Algorithm Description
Intel RealSense RGBD \`.bag\` → cwipc-native reconstruction (N0 official filter) → consumer-grade CG PLY → SuperPC enhancement.
88 hard frames use official CG fallback at Stage1 when reconstruction fails.

## Processing Track
**Full Pipeline** (input: RGBD \`.bag\`)

## How to Run

See [SETUP.md](SETUP.md). Requires **librealsense + cwipc** for Stage1 (\`bash src/install_cwipc.sh\` on supported Linux).

\`\`\`bash
export GC2026_ROOT=/path/to/workspace
cd submissions/GC2026_Team_FullPipeline
conda activate superpc
bash src/run.sh              # full 2155 frames (GPU + CPU)
# or smoke: bash src/run_official_val_smoke.sh
\`\`\`

Outputs:
- Recon CG: \`\$GC2026_ROOT/output/full_pipeline_n0_v2_cg/\`
- ENH: \`\$GC2026_ROOT/output/full_pipeline_n0_v2_candidate/\`

Post: \`bash src/post_full_pipeline.sh\`

## Hardware / Environment
- Stage1: CPU (cwipc, multi-job); Stage2: 2× NVIDIA RTX 5090
- Ubuntu 22.04, Python 3.9 / 3.12 for Stage1 scripts

## Runtime
See \`output/full_pipeline_n0_v2_candidate/runtime.log\`.

## Selected SuperPC config
See \`config/gate_config.json\`.

## Official val565 result (local cd_l1, after backfill fix, Jun 2026)
- ENH vs HE mean: **158.7 mm** (Stage1 bottleneck; Enh Only reference: 48.5 mm)
EOF
}

write_enh_run() {
  cat > "${ENH_DIR}/src/run_smoke.sh" <<'EOF'
#!/usr/bin/env bash
# Official-style smoke: 2 val CG frames -> ENH (for organizers / CI).
set -euo pipefail
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SRC_DIR}/common.sh"

SMOKE_FRAMES="${SMOKE_FRAMES:-2}"
OUT_DIR="${OUT_DIR:-${GC2026_ROOT}/output/submission_smoke}"
VAL_CG="${GC2026_ROOT}/data/processed/val_cg_only_official_cgv2.txt"
mkdir -p "$OUT_DIR"
head -n "$SMOKE_FRAMES" "$VAL_CG" > "$OUT_DIR/smoke_cg_list.txt"
export OUT_DIR CG_LIST="$OUT_DIR/smoke_cg_list.txt"
export GATE_JSON="${SUBMISSION_ROOT}/config/gate_decision.json"
export ENH_PER_SEQ_CONFIG="${ENH_PER_SEQ_CONFIG:-${SUBMISSION_ROOT}/config/per_sequence_enh_config.json}"
export UVG_CG_VERSION="${UVG_CG_VERSION:-v2}"
bash "${SRC_DIR}/run.sh"
echo "[run_smoke] DONE frames=$SMOKE_FRAMES -> $OUT_DIR"
EOF
  chmod +x "${ENH_DIR}/src/run_smoke.sh"

  cat > "${ENH_DIR}/src/gc2026_paths.py" <<'EOF'
"""Resolve GC2026 workspace root from submission package or project scripts/."""
from __future__ import annotations

import os


def resolve_gc2026_root(script_dir: str) -> str:
    env = os.environ.get("GC2026_ROOT", "").strip()
    if env:
        return os.path.abspath(env)
    sub_root = os.path.dirname(os.path.abspath(script_dir))
    workspace = os.path.abspath(os.path.join(sub_root, "..", ".."))
    if os.path.isdir(os.path.join(workspace, "data")) and os.path.isdir(
        os.path.join(workspace, "code", "SuperPC")
    ):
        return workspace
    if os.path.isdir(os.path.join(sub_root, "data")):
        return sub_root
    return workspace
EOF

  cat > "${ENH_DIR}/src/run.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SRC_DIR}/common.sh"

export OUT_DIR="${OUT_DIR:-${GC2026_ROOT}/output/submission_candidate}"
export GATE_JSON="${SUBMISSION_ROOT}/config/gate_decision.json"
export ENH_PER_SEQ_CONFIG="${ENH_PER_SEQ_CONFIG:-${SUBMISSION_ROOT}/config/per_sequence_enh_config.json}"
export UVG_CG_VERSION="${UVG_CG_VERSION:-v2}"

if [[ -f "$GATE_JSON" ]]; then
  eval "$(python3 -c "
import json, os
g=json.load(open('$GATE_JSON'))
c=g.get('best_config',{})
ckpt=os.path.join('$GC2026_ROOT', 'models/superpc_pretrained', c.get('checkpoint','kitti360_com.pth'))
print(f'export CKPT={ckpt}')
print(f'export OUTPUT_MODE={c.get(\"output_mode\",\"blend_cg\")}')
print(f'export BLEND_VOXEL_MM={c.get(\"blend_voxel_mm\",3.0)}')
print(f'export USE_VISION={c.get(\"use_vision\",0)}')
")"
fi

if [[ -z "${CG_LIST:-}" ]]; then
  if [[ -f "${GC2026_ROOT}/data/processed/all_cg_only_cgv2.txt" ]]; then
    export CG_LIST="${GC2026_ROOT}/data/processed/all_cg_only_cgv2.txt"
  else
    export CG_LIST="${GC2026_ROOT}/data/processed/all_cg_only.txt"
  fi
fi

export CKPT="${CKPT:-${GC2026_ROOT}/models/superpc_pretrained/kitti360_com.pth}"
export OUTPUT_MODE="${OUTPUT_MODE:-blend_cg}"
export BLEND_VOXEL_MM="${BLEND_VOXEL_MM:-3.0}"
export NUM_POINTS="${NUM_POINTS:-11520}"
export TARGET_NUM_POINTS="${TARGET_NUM_POINTS:-46080}"

bash "${SRC_DIR}/run_dual_gpu_infer.sh"
echo "[run.sh] DONE -> $OUT_DIR"
EOF
  chmod +x "${ENH_DIR}/src/run.sh"
}

write_full_run() {
  cat > "${FULL_DIR}/src/run.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SRC_DIR}/common.sh"

export RECON_ROOT="${RECON_ROOT:-${GC2026_ROOT}/output/full_pipeline_n0_v2_cg}"
export ENH_ROOT="${ENH_ROOT:-${GC2026_ROOT}/output/full_pipeline_n0_v2_candidate}"
export STAGE1_TAG="${STAGE1_TAG:-N0_cwipc_official}"
export UVG_VAL_PAIRS_FILE="${UVG_VAL_PAIRS_FILE:-${GC2026_ROOT}/data/processed/val_pairs_official_cgv2.txt}"

bash "${SRC_DIR}/run_full_n0_v2.sh"
EOF
  chmod +x "${FULL_DIR}/src/run.sh"
}

copy_processed_lists() {
  local dest="$1"
  mkdir -p "${dest}/data/processed"
  for f in all_cg_only_cgv2.txt all_pairs_cgv2.txt val_pairs_official_cgv2.txt \
           val_cg_only_official_cgv2.txt train_pairs_official_cgv2.txt; do
    [[ -f "${GC2026_ROOT}/data/processed/${f}" ]] && \
      cp -f "${GC2026_ROOT}/data/processed/${f}" "${dest}/data/processed/${f}"
  done
  cat > "${dest}/data/processed/README.txt" <<EOF
Copy these files to \$GC2026_ROOT/data/processed/ if not already present.
EOF
}

# --- Enhancement Only ---
echo "[build] Enhancement Only -> ${ENH_DIR}"
rm -rf "$ENH_DIR"
mkdir -p "${ENH_DIR}/src"
ENH_SCRIPTS=(
  gc2026_paths.py run_dual_gpu_infer.sh run_superpc_infer.py split_pending_cg_list.py
  uvg_io.py make_submission.py write_runtime_summary.py
  build_per_sequence_enh_config.py post_submission_candidate.sh
  evaluate_uvg.py summarize_eval_by_sequence.py download_pretrained.sh
  create_init_ckpt.py verify_superpc_ckpt.py
)
copy_scripts "${ENH_DIR}/src" "${ENH_SCRIPTS[@]}"
write_env_setup "${ENH_DIR}/src"
patch_scripts "${ENH_DIR}/src"
write_gate_config "$ENH_DIR"
write_requirements "$ENH_DIR"
write_setup_md "$ENH_DIR"
write_enh_readme
write_enh_run
copy_processed_lists "$ENH_DIR"
sed -i 's|GATE_JSON="${GC2026_ROOT}/output/val_grid/gate_decision.json"|GATE_JSON="${SUBMISSION_ROOT}/config/gate_decision.json"|g' \
  "${ENH_DIR}/src/post_submission_candidate.sh" 2>/dev/null || true

# --- Full Pipeline ---
echo "[build] Full Pipeline -> ${FULL_DIR}"
rm -rf "$FULL_DIR"
mkdir -p "${FULL_DIR}/src"
FULL_SCRIPTS=(
  run_full_n0_v2.sh run_stage1_native_parallel.sh run_official_val_smoke.sh
  run_stage1_backfill_fix.sh apply_official_cg_fallback.py copy_enh_from_submission.py
  rgbd_to_cg.py retry_missing_recon.py cwipc_filter_profiles.py
  run_dual_gpu_infer.sh run_superpc_infer.py split_pending_cg_list.py
  uvg_io.py uvg_splits.py build_split_pairs.py make_submission.py
  write_runtime_summary.py post_full_pipeline.sh post_submission_candidate.sh
  compare_reconstructed_cg.py build_recon_enh_config.py build_per_sequence_enh_config.py
  evaluate_uvg.py evaluate_recon_pipeline.py summarize_eval_by_sequence.py
  download_pretrained.sh create_init_ckpt.py verify_superpc_ckpt.py
  install_cwipc.sh env_setup.sh diagnose_stage1.py eval_native_gate.py
)
copy_scripts "${FULL_DIR}/src" "${FULL_SCRIPTS[@]}"
write_env_setup "${FULL_DIR}/src"
patch_scripts "${FULL_DIR}/src"
inject_common_header "${FULL_DIR}/src/run_full_n0_v2.sh"
sed -i 's|SCRIPT_DIR="\${GC2026_ROOT}/scripts"|SCRIPT_DIR="\${SRC_DIR}"|g' "${FULL_DIR}/src/run_full_n0_v2.sh"

write_gate_config "$FULL_DIR"
write_requirements "$FULL_DIR"
write_setup_md "$FULL_DIR"
write_full_readme
write_full_run
copy_processed_lists "$FULL_DIR"
sed -i 's|GATE_JSON="${GC2026_ROOT}/output/val_grid/gate_decision.json"|GATE_JSON="${SUBMISSION_ROOT}/config/gate_decision.json"|g' \
  "${FULL_DIR}/src/post_full_pipeline.sh" 2>/dev/null || true

# Copy manifests from latest output
[[ -f "${GC2026_ROOT}/output/submission_candidate/manifest.json" ]] && \
  cp -f "${GC2026_ROOT}/output/submission_candidate/manifest.json" "${ENH_DIR}/manifest.json"
[[ -f "${GC2026_ROOT}/output/full_pipeline_n0_v2_candidate/manifest.json" ]] && \
  cp -f "${GC2026_ROOT}/output/full_pipeline_n0_v2_candidate/manifest.json" "${FULL_DIR}/manifest.json"

# --- Tarballs ---
echo "[build] packing tarballs..."
tar -czf "${OUT_BASE}/GC2026_submission_EnhancementOnly.tar.gz" -C "${GC2026_ROOT}/submissions" "${ENH_NAME}"
tar -czf "${OUT_BASE}/GC2026_submission_FullPipeline.tar.gz" -C "${GC2026_ROOT}/submissions" "${FULL_NAME}"

ls -lh "${OUT_BASE}/GC2026_submission_EnhancementOnly.tar.gz" "${OUT_BASE}/GC2026_submission_FullPipeline.tar.gz"
echo "[build] DONE"
echo "  Enh:  ${ENH_DIR}"
echo "  Full: ${FULL_DIR}"
