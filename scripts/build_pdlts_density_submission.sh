#!/usr/bin/env bash
# Build Enhancement Only submission package: PD-LTS light + density_adaptive refine.
set -euo pipefail

GC2026_ROOT="${GC2026_ROOT:-/root/autodl-tmp/GC2026}"
SCRIPT_DIR="${GC2026_ROOT}/scripts"
ENH_NAME="GC2026_Team_EnhancementOnly"
ENH_DIR="${GC2026_ROOT}/submissions/${ENH_NAME}"
GATE_SRC="${GATE_SRC:-${GC2026_ROOT}/output/enh_refine_p0_p1_p2/gate_decision.json}"
PDLTS_REPO="${PDLTS_REPO:-https://github.com/yanbiao1/PD-LTS.git}"

echo "[build_pdlts] ENH_DIR=$ENH_DIR"
mkdir -p "${ENH_DIR}/src" "${ENH_DIR}/config" "${ENH_DIR}/data/processed"

copy_py() {
  for f in "$@"; do
    cp -f "${SCRIPT_DIR}/${f}" "${ENH_DIR}/src/"
  done
}

copy_py \
  gc2026_paths.py \
  run_pdlts_infer.py \
  run_enh_refine_infer.py \
  enh_refine_config.py \
  enh_refine_pipeline.py \
  enh_geometry_sources.py \
  uvg_io.py \
  split_pending_cg_list.py \
  make_submission.py \
  write_runtime_summary.py \
  evaluate_gc_baseline_metrics.py

# Pair lists (official)
for f in all_cg_only_cgv2.txt val_cg_only_official_cgv2.txt val_pairs_official_cgv2.txt \
  all_pairs_cgv2.txt train_pairs_official_cgv2.txt; do
  src="${GC2026_ROOT}/data/processed/${f}"
  [[ -f "$src" ]] && cp -f "$src" "${ENH_DIR}/data/processed/${f}"
done
[[ -f "${ENH_DIR}/data/processed/README.txt" ]] || echo "Official pair lists for UVG-CWI-DQPC." > "${ENH_DIR}/data/processed/README.txt"

# Gate: pdlts_light_snap1_fill0.6_density (no VH snap=0)
if [[ ! -f "$GATE_SRC" ]]; then
  echo "[build_pdlts] missing gate: $GATE_SRC" >&2
  exit 1
fi
cp -f "$GATE_SRC" "${ENH_DIR}/config/gate_decision.json"
python3 -c "
import json
g=json.load(open('${ENH_DIR}/config/gate_decision.json'))
cfg=g.get('production_config', g.get('best_config', g))
json.dump(cfg, open('${ENH_DIR}/config/gate_config.json','w'), indent=2)
print('[build_pdlts] gate_config:', cfg.get('name'))
"

cat > "${ENH_DIR}/src/common.sh" <<'EOF'
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
export SCRIPT_DIR="${SRC_DIR}"
export PY="${PY:-python3}"

if [[ -f "${SRC_DIR}/env_setup.sh" ]] && [[ "${SUBMISSION_SKIP_CONDA:-0}" != "1" ]]; then
  if [[ -f "${HOME}/miniconda3/etc/profile.d/conda.sh" ]]; then
    # shellcheck source=/dev/null
    source "${HOME}/miniconda3/etc/profile.d/conda.sh"
    conda activate superpc 2>/dev/null || true
    export PATH="${CONDA_PREFIX:-}/bin:${PATH}"
    export PYTHON="${CONDA_PREFIX:-}/bin/python3.9"
  fi
fi

export PYTHON="${PYTHON:-python3}"
export UVG_VAL_PAIRS_FILE="${UVG_VAL_PAIRS_FILE:-${GC2026_ROOT}/data/processed/val_pairs_official_cgv2.txt}"
EOF
chmod +x "${ENH_DIR}/src/common.sh"

cat > "${ENH_DIR}/src/env_setup.sh" <<'EOF'
#!/usr/bin/env bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
EOF
chmod +x "${ENH_DIR}/src/env_setup.sh"

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
        os.path.join(workspace, "code", "PD-LTS")
    ):
        return workspace
    if os.path.isdir(os.path.join(sub_root, "data")):
        return sub_root
    return workspace
EOF

cat > "${ENH_DIR}/src/setup_pdlts_deps.sh" <<'EOF'
#!/usr/bin/env bash
# Install PD-LTS inference deps (pytorch3d, torch-cluster, chamfer3D).
set -euo pipefail
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SRC_DIR}/common.sh"

if [[ -f "${HOME}/miniconda3/etc/profile.d/conda.sh" ]]; then
  source "${HOME}/miniconda3/etc/profile.d/conda.sh"
  conda activate superpc
fi

pip install -q ninja scikit-learn fvcore iopath
pip install -q torch-cluster -f https://data.pyg.org/whl/torch-2.8.0+cu128.html
pip install -q --extra-index-url https://miropsota.github.io/torch_packages_builder \
  "pytorch3d==0.7.8+pt2.8.0cu128"

cd "${PDLTS_ROOT}/metric/PyTorchCD/chamfer3D"
python setup.py install -q

for f in "${PDLTS_ROOT}/models/layers/base/pila.cu" "${PDLTS_ROOT}/modules/base/pila.cu"; do
  if [[ -f "$f" ]] && grep -q 'x\.type()' "$f" 2>/dev/null; then
    sed -i 's/x\.type()/x.scalar_type()/g' "$f"
  fi
done
echo "[setup_pdlts_deps] OK"
EOF
chmod +x "${ENH_DIR}/src/setup_pdlts_deps.sh"

cat > "${ENH_DIR}/src/download_pdlts.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
SRC_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
source "\${SRC_DIR}/common.sh"
mkdir -p "\${GC2026_ROOT}/code"
if [[ ! -d "\${PDLTS_ROOT}/.git" ]]; then
  git clone ${PDLTS_REPO} "\${PDLTS_ROOT}"
fi
CKPT="\${PDLTS_ROOT}/product/ckpt/Denoiseflow-light-FBM.ckpt"
if [[ ! -f "\$CKPT" ]]; then
  echo "Checkpoint missing: \$CKPT"
  echo "Download from PD-LTS release / Google Drive (see PD-LTS README) into product/ckpt/"
  exit 1
fi
echo "[download_pdlts] OK \$CKPT"
EOF
chmod +x "${ENH_DIR}/src/download_pdlts.sh"

cat > "${ENH_DIR}/src/verify_pdlts_ckpt.py" <<'EOF'
#!/usr/bin/env python3
"""Smoke-check PD-LTS light checkpoint loads."""
from __future__ import annotations

import argparse
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--ckpt-path", required=True)
    args = p.parse_args()
    if not os.path.isfile(args.ckpt_path):
        raise SystemExit(f"missing: {args.ckpt_path}")
    import run_pdlts_infer as pdlts  # noqa: WPS433

    get_net, _, _ = pdlts.load_denoise_module("light")
    net = get_net(args.ckpt_path)
    print("OK", type(net).__name__, args.ckpt_path)


if __name__ == "__main__":
    main()
EOF

cat > "${ENH_DIR}/src/run_dual_gpu_pdlts.sh" <<'EOF'
#!/usr/bin/env bash
# Shard PD-LTS light inference across visible GPUs.
set -euo pipefail
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SRC_DIR}/common.sh"

CG_LIST="${CG_LIST:?CG_LIST required}"
GEOMETRY_DIR="${GEOMETRY_DIR:-${GC2026_ROOT}/output/pdlts_geometry/light}"
NUM_GPUS="${NUM_GPUS:-$(nvidia-smi -L 2>/dev/null | wc -l)}"
NUM_GPUS="${NUM_GPUS:-1}"
if [[ "$NUM_GPUS" -lt 1 ]]; then NUM_GPUS=1; fi

mkdir -p "$GEOMETRY_DIR"
SHARD_DIR="${GEOMETRY_DIR}/.shards_${NUM_GPUS}gpu"
mkdir -p "$SHARD_DIR"

"$PYTHON" "${SRC_DIR}/split_pending_cg_list.py" \
  --cg-list "$CG_LIST" \
  --out-dir "$GEOMETRY_DIR" \
  --shard-dir "$SHARD_DIR" \
  --num-shards "$NUM_GPUS"

pids=()
for i in $(seq 0 $((NUM_GPUS - 1))); do
  list="${SHARD_DIR}/pending_${i}.txt"
  [[ -s "$list" ]] || continue
  gpu=$((i % NUM_GPUS))
  CUDA_VISIBLE_DEVICES=$gpu "$PYTHON" "${SRC_DIR}/run_pdlts_infer.py" \
    --cg-list "$list" \
    --out-dir "$GEOMETRY_DIR" \
    --model light \
    --skip-existing &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid"; done
echo "[run_dual_gpu_pdlts] DONE -> $GEOMETRY_DIR"
EOF
chmod +x "${ENH_DIR}/src/run_dual_gpu_pdlts.sh"

cat > "${ENH_DIR}/src/run.sh" <<'EOF'
#!/usr/bin/env bash
# Enhancement Only: official CG -> PD-LTS light -> snap/fill density refine.
set -euo pipefail
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SRC_DIR}/common.sh"

export OUT_DIR="${OUT_DIR:-${GC2026_ROOT}/output/submission_candidate_pdlts_density}"
export GATE_JSON="${GATE_JSON:-${SUBMISSION_ROOT}/config/gate_decision.json}"
export GEOMETRY_DIR="${GEOMETRY_DIR:-${GC2026_ROOT}/output/pdlts_geometry/light}"
export UVG_CG_VERSION="${UVG_CG_VERSION:-v2}"
export SKIP_PDLTS="${SKIP_PDLTS:-0}"

if [[ -z "${CG_LIST:-}" ]]; then
  if [[ -f "${GC2026_ROOT}/data/processed/all_cg_only_cgv2.txt" ]]; then
    export CG_LIST="${GC2026_ROOT}/data/processed/all_cg_only_cgv2.txt"
  else
    export CG_LIST="${GC2026_ROOT}/data/processed/all_cg_only.txt"
  fi
fi

"${SRC_DIR}/download_pdlts.sh"

if [[ "$SKIP_PDLTS" != "1" ]]; then
  echo "[run.sh] Stage1 PD-LTS geometry -> $GEOMETRY_DIR"
  bash "${SRC_DIR}/run_dual_gpu_pdlts.sh"
fi

echo "[run.sh] Stage2 refine (pdlts_light_snap1_fill0.6_density) -> $OUT_DIR"
"$PYTHON" "${SRC_DIR}/run_enh_refine_infer.py" \
  --cg-list "$CG_LIST" \
  --out-dir "$OUT_DIR" \
  --refine-config "$GATE_JSON" \
  --geometry-dir "$GEOMETRY_DIR" \
  --use-geometry-cache \
  --require-geometry-cache

echo "[run.sh] DONE -> $OUT_DIR"
EOF
chmod +x "${ENH_DIR}/src/run.sh"

cat > "${ENH_DIR}/src/run_smoke.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SRC_DIR}/common.sh"

SMOKE_FRAMES="${SMOKE_FRAMES:-2}"
OUT_DIR="${OUT_DIR:-${GC2026_ROOT}/output/submission_smoke}"
VAL_CG="${GC2026_ROOT}/data/processed/val_cg_only_official_cgv2.txt"
mkdir -p "$OUT_DIR"
head -n "$SMOKE_FRAMES" "$VAL_CG" > "$OUT_DIR/smoke_cg_list.txt"
export OUT_DIR CG_LIST="$OUT_DIR/smoke_cg_list.txt"
export GEOMETRY_DIR="${GEOMETRY_DIR:-$OUT_DIR/pdlts_geometry}"
export GATE_JSON="${SUBMISSION_ROOT}/config/gate_decision.json"
export UVG_CG_VERSION="${UVG_CG_VERSION:-v2}"
bash "${SRC_DIR}/run.sh"
echo "[run_smoke] DONE frames=$SMOKE_FRAMES -> $OUT_DIR"
EOF
chmod +x "${ENH_DIR}/src/run_smoke.sh"

cat > "${ENH_DIR}/src/post_submission_candidate.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SRC_DIR}/common.sh"

OUT="${OUT_DIR:-${GC2026_ROOT}/output/submission_candidate_pdlts_density}"
GATE_JSON="${SUBMISSION_ROOT}/config/gate_decision.json"
VAL_PAIRS="${UVG_VAL_PAIRS_FILE}"

n=$(find "$OUT" -name '*.ply' 2>/dev/null | wc -l)
echo "[post] ply_count=$n"

"$PYTHON" "${SRC_DIR}/write_runtime_summary.py" --out-dir "$OUT" --team "GC2026 Team" || true
"$PYTHON" "${SRC_DIR}/make_submission.py" \
  --enhanced-dir "$OUT" \
  --team "GC2026 Team" \
  --processing-track "Enhancement Only" \
  --title "UVG-CWI-DQPC GC2026 Enhancement Only PD-LTS density" \
  --post-processing "$GATE_JSON" \
  --cg-version "${UVG_CG_VERSION:-v2}" \
  --cg-source "official" \
  --data-split "official_val=TrumanShow,VictoryHeart,VirtualLife" \
  --pipeline-notes "Official CGv2 -> PD-LTS light -> snap 1mm + density_adaptive fill 0.6mm"

if [[ -f "$VAL_PAIRS" ]]; then
  "$PYTHON" "${SRC_DIR}/evaluate_gc_baseline_metrics.py" \
    --pairs-file "$VAL_PAIRS" \
    --test-root "$OUT" \
    --test-mode enh \
    --out-json "${OUT}/evaluation_gc_baseline_val565.json" \
    --also-cg || true
fi
echo "[post] DONE"
EOF
chmod +x "${ENH_DIR}/src/post_submission_candidate.sh"

cat > "${ENH_DIR}/requirements.txt" <<'EOF'
torch>=2.0
numpy
scipy
open3d
plyfile
tqdm
scikit-learn
ninja
fvcore
iopath
EOF

cat > "${ENH_DIR}/SETUP.md" <<'EOF'
# Environment setup (organizers / reproducers)

## 1. Workspace layout

```text
/workspace/                         ← export GC2026_ROOT=/workspace
  code/PD-LTS/                      ← git clone https://github.com/yanbiao1/PD-LTS
  data/raw/UVG-CWI-DQPC/            ← official dataset (CG PLY)
  data/processed/                   ← pair lists (included in package data/processed/)
  submissions/GC2026_Team_EnhancementOnly/
```

## 2. Python environment

```bash
conda create -n superpc python=3.9 -y && conda activate superpc
pip install -r requirements.txt
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu128
```

## 3. PD-LTS + checkpoint

```bash
export GC2026_ROOT=/path/to/workspace
cd submissions/GC2026_Team_EnhancementOnly
bash src/download_pdlts.sh          # clones PD-LTS; needs Denoiseflow-light-FBM.ckpt
bash src/setup_pdlts_deps.sh        # pytorch3d + chamfer3D extension
```

Primary checkpoint: **Denoiseflow-light-FBM.ckpt** under `code/PD-LTS/product/ckpt/`.

Refine preset: **pdlts_light_snap1_fill0.6_density** (see `config/gate_config.json`).
EOF

cat > "${ENH_DIR}/README.md" <<'EOF'
# GC2026 Team — Enhancement Only (PD-LTS + density refine)

## Team Name
GC2026 Team

## Team Members
- *(Update before PR)* Member 1 — Affiliation
- *(Update before PR)* Member 2 — Affiliation

## Algorithm Name
PD-LTS light + snap/fill density_adaptive (`pdlts_light_snap1_fill0.6_density`)

## Algorithm Description
Official consumer-grade CG PLY (v2) → **PD-LTS** light denoising (frozen `Denoiseflow-light-FBM.ckpt`) → geometric refinement: snap to denoised geometry (1.0 mm) + density-adaptive hole fill (0.6 mm base). KNN color transfer from input CG. No fine-tuning on UVG data; no per-sequence snap overrides.

## Processing Track
**Enhancement Only** (input: official CG `.ply` files only; no RGBD `.bag` required)

## How to Run

See [SETUP.md](SETUP.md) for PD-LTS clone, checkpoint, and `setup_pdlts_deps.sh`.

```bash
export GC2026_ROOT=/path/to/workspace
cd submissions/GC2026_Team_EnhancementOnly
conda activate superpc
bash src/run.sh
```

Outputs: `$GC2026_ROOT/output/submission_candidate_pdlts_density/` (2155 ENH PLY).

**Smoke test (2 val frames):** `bash src/run_smoke.sh`

Optional: `bash src/post_submission_candidate.sh` (manifest + val565 gc_baseline eval)

## Hardware / Environment
- NVIDIA GPU recommended (dual-GPU PD-LTS sharding when 2+ GPUs visible)
- Ubuntu 22.04, Python 3.9, PyTorch 2.8+cu128 (RTX 5090 tested)
- Coordinate system: consumer-grade capture coordinates (mm), same as input CG

## Runtime
Stage1 PD-LTS + Stage2 CPU/GPU refine. See `output/submission_candidate/runtime.log` after full run.

## Selected config
See `config/gate_config.json` — preset `pdlts_light_snap1_fill0.6_density`.

## Local validation (gc_baseline aligned, official val565)
- CG baseline chamfer_distance: **17.552 mm**
- This submission ENH (density, global snap=1): **17.504 mm** (564 val frames)
EOF

# Remove SuperPC-only entrypoints from prior package
rm -f "${ENH_DIR}/src/run_superpc_infer.py" \
  "${ENH_DIR}/src/run_dual_gpu_infer.sh" \
  "${ENH_DIR}/src/verify_superpc_ckpt.py" \
  "${ENH_DIR}/src/download_pretrained.sh" \
  "${ENH_DIR}/src/create_init_ckpt.py" \
  "${ENH_DIR}/config/per_sequence_enh_config.json" \
  "${ENH_DIR}/config/recon_enh_config.json" 2>/dev/null || true

# py_compile sanity
while IFS= read -r -d '' f; do python3 -m py_compile "$f"; done < <(find "${ENH_DIR}/src" -name '*.py' -print0)
bash -n "${ENH_DIR}/src/run.sh"
bash -n "${ENH_DIR}/src/run_smoke.sh"

echo "[build_pdlts] DONE $ENH_DIR"
