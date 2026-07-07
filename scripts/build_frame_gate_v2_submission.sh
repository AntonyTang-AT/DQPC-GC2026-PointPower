#!/usr/bin/env bash
# Build Enhancement Only submission: ft PD-LTS + SuperPC CG-hole hybrid (frame_gate v2).
set -euo pipefail

GC2026_ROOT="${GC2026_ROOT:-/root/autodl-tmp/GC2026}"
SCRIPT_DIR="${GC2026_ROOT}/scripts"
ENH_NAME="GC2026_Team_EnhancementOnly"
ENH_DIR="${GC2026_ROOT}/submissions/${ENH_NAME}"
PDLTS_REPO="${PDLTS_REPO:-https://github.com/yanbiao1/PD-LTS.git}"
SUPERPC_REPO="${SUPERPC_REPO:-https://github.com/sair-lab/SuperPC.git}"
FINETUNE_CKPT_SRC="${FINETUNE_CKPT_SRC:-$(ls -t "${GC2026_ROOT}/output/pdlts_finetune_uvg"/run_*/DenoiseFlow-light-UVG-finetune.ckpt 2>/dev/null | head -1)}"

echo "[build_frame_gate_v2] ENH_DIR=$ENH_DIR"
mkdir -p "${ENH_DIR}/src" "${ENH_DIR}/config" "${ENH_DIR}/data/processed" "${ENH_DIR}/models"

copy_py() {
  for f in "$@"; do
    cp -f "${SCRIPT_DIR}/${f}" "${ENH_DIR}/src/"
  done
}

copy_py \
  gc2026_paths.py \
  run_pdlts_infer.py \
  run_superpc_infer.py \
  run_enh_refine_infer.py \
  enh_refine_config.py \
  enh_refine_pipeline.py \
  frame_fill_gate.py \
  enh_geometry_sources.py \
  uvg_io.py \
  split_pending_cg_list.py \
  make_submission.py \
  write_runtime_summary.py \
  evaluate_gc_baseline_metrics.py \
  evaluate_uvg.py \
  enh_temporal.py \
  enh_temporal_attention.py \
  enh_temporal_region.py \
  run_pdlts_finetune_uvg.py \
  pdlts_uvg_train_dataset.py

for sh in run_pdlts_finetune_uvg.sh setup_pdlts_train.sh download_metric.sh install_finetuned_ckpt.sh; do
  cp -f "${SCRIPT_DIR}/${sh}" "${ENH_DIR}/src/" 2>/dev/null || cp -f "${ENH_DIR}/src/${sh}" "${ENH_DIR}/src/" 2>/dev/null || true
  [[ -f "${ENH_DIR}/src/${sh}" ]] || cp -f "${GC2026_ROOT}/submissions/GC2026_Team_EnhancementOnly/src/${sh}" "${ENH_DIR}/src/"
  chmod +x "${ENH_DIR}/src/${sh}"
done

for f in all_cg_only_cgv2.txt val_cg_only_official_cgv2.txt val_pairs_official_cgv2.txt \
  all_pairs_cgv2.txt train_pairs_official_cgv2.txt; do
  src="${GC2026_ROOT}/data/processed/${f}"
  [[ -f "$src" ]] && cp -f "$src" "${ENH_DIR}/data/processed/${f}"
done
[[ -f "${ENH_DIR}/data/processed/README.txt" ]] || echo "Official pair lists for UVG-CWI-DQPC." > "${ENH_DIR}/data/processed/README.txt"

python3 <<PY
import json, sys
sys.path.insert(0, "${SCRIPT_DIR}")
from enh_refine_config import resolve_preset
cfg = resolve_preset("holefill_adaptive_frame_gate_v2")
d = cfg.to_dict()
gate = {
    "production_config": d,
    "best_config": d,
    "preset_name": cfg.name,
    "geometry_mode": "hybrid",
    "geometry_primary": "pdlts_finetune_light",
    "geometry_secondary": "superpc_blend_cg",
    "val565_chamfer_mm": 14.8699,
    "val565_chamfer_mm_ft_baseline": 14.8831,
}
json.dump(gate, open("${ENH_DIR}/config/gate_decision.json", "w"), indent=2)
json.dump(d, open("${ENH_DIR}/config/gate_config.json", "w"), indent=2)
print("[build_frame_gate_v2] gate:", cfg.name)
PY

if [[ -f "$FINETUNE_CKPT_SRC" ]]; then
  cp -f "$FINETUNE_CKPT_SRC" "${ENH_DIR}/models/DenoiseFlow-light-UVG-finetune.ckpt"
  echo "[build_frame_gate_v2] bundled finetune ckpt"
else
  echo "[build_frame_gate_v2] WARN: no finetune ckpt at FINETUNE_CKPT_SRC" >&2
fi

cp -f "${ENH_DIR}/src/common.sh" "${ENH_DIR}/src/common.sh.bak" 2>/dev/null || true
cp -f "${GC2026_ROOT}/submissions/GC2026_Team_EnhancementOnly/src/common.sh" "${ENH_DIR}/src/common.sh" 2>/dev/null || \
  cp -f "${SCRIPT_DIR}/../submissions/GC2026_Team_EnhancementOnly/src/common.sh" "${ENH_DIR}/src/common.sh"
chmod +x "${ENH_DIR}/src/common.sh"

cat > "${ENH_DIR}/src/env_setup.sh" <<'EOF'
#!/usr/bin/env bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
EOF
chmod +x "${ENH_DIR}/src/env_setup.sh"

cat > "${ENH_DIR}/src/setup_pdlts_deps.sh" <<'EOF'
#!/usr/bin/env bash
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
if [[ ! -f "\${PDLTS_FINETUNE_CKPT}" ]]; then
  echo "Missing finetune ckpt: \${PDLTS_FINETUNE_CKPT}" >&2
  exit 1
fi
echo "[download_pdlts] finetune ckpt OK"
EOF
chmod +x "${ENH_DIR}/src/download_pdlts.sh"

cat > "${ENH_DIR}/src/download_pretrained.sh" <<'EOF'
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
EOF
chmod +x "${ENH_DIR}/src/download_pretrained.sh"

cat > "${ENH_DIR}/src/run_dual_gpu_pdlts.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SRC_DIR}/common.sh"
CG_LIST="${CG_LIST:?CG_LIST required}"
GEOMETRY_DIR="${GEOMETRY_DIR:-${GC2026_ROOT}/output/pdlts_finetune_geometry/light}"
NUM_GPUS="${NUM_GPUS:-$(nvidia-smi -L 2>/dev/null | wc -l)}"
NUM_GPUS="${NUM_GPUS:-1}"
[[ "$NUM_GPUS" -lt 1 ]] && NUM_GPUS=1
mkdir -p "$GEOMETRY_DIR"
SHARD_DIR="${GEOMETRY_DIR}/.shards_${NUM_GPUS}gpu"
mkdir -p "$SHARD_DIR"
"$PYTHON" "${SRC_DIR}/split_pending_cg_list.py" \
  --cg-list "$CG_LIST" --out-dir "$GEOMETRY_DIR" --shard-dir "$SHARD_DIR" --num-shards "$NUM_GPUS"
pids=()
for i in $(seq 0 $((NUM_GPUS - 1))); do
  list="${SHARD_DIR}/pending_${i}.txt"
  [[ -s "$list" ]] || continue
  gpu=$((i % NUM_GPUS))
  CUDA_VISIBLE_DEVICES=$gpu "$PYTHON" "${SRC_DIR}/run_pdlts_infer.py" \
    --cg-list "$list" --out-dir "$GEOMETRY_DIR" --model light \
    --ckpt "${PDLTS_FINETUNE_CKPT}" --skip-existing &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid"; done
echo "[run_dual_gpu_pdlts] DONE -> $GEOMETRY_DIR"
EOF
chmod +x "${ENH_DIR}/src/run_dual_gpu_pdlts.sh"

cat > "${ENH_DIR}/src/run_dual_gpu_superpc.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SRC_DIR}/common.sh"
CG_LIST="${CG_LIST:?CG_LIST required}"
GEOMETRY_SECONDARY_DIR="${GEOMETRY_SECONDARY_DIR:-${GC2026_ROOT}/output/superpc_geometry/blend_cg}"
NUM_GPUS="${NUM_GPUS:-$(nvidia-smi -L 2>/dev/null | wc -l)}"
NUM_GPUS="${NUM_GPUS:-1}"
[[ "$NUM_GPUS" -lt 1 ]] && NUM_GPUS=1
mkdir -p "$GEOMETRY_SECONDARY_DIR"
SHARD_DIR="${GEOMETRY_SECONDARY_DIR}/.shards_${NUM_GPUS}gpu"
mkdir -p "$SHARD_DIR"
"$PYTHON" "${SRC_DIR}/split_pending_cg_list.py" \
  --cg-list "$CG_LIST" --out-dir "$GEOMETRY_SECONDARY_DIR" --shard-dir "$SHARD_DIR" --num-shards "$NUM_GPUS"
pids=()
for i in $(seq 0 $((NUM_GPUS - 1))); do
  list="${SHARD_DIR}/pending_${i}.txt"
  [[ -s "$list" ]] || continue
  gpu=$((i % NUM_GPUS))
  CUDA_VISIBLE_DEVICES=$gpu "$PYTHON" "${SRC_DIR}/run_superpc_infer.py" \
    --cg-list "$list" --out-dir "$GEOMETRY_SECONDARY_DIR" \
    --ckpt-path "${SUPERPC_CKPT}" --output-mode blend_cg --blend-voxel-mm 3.0 \
    --skip-existing &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid"; done
echo "[run_dual_gpu_superpc] DONE -> $GEOMETRY_SECONDARY_DIR"
EOF
chmod +x "${ENH_DIR}/src/run_dual_gpu_superpc.sh"

cat > "${ENH_DIR}/src/run.sh" <<'EOF'
#!/usr/bin/env bash
# Enhancement Only: CG -> ft PD-LTS -> SuperPC blend_cg -> frame_gate v2 hybrid refine.
set -euo pipefail
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SRC_DIR}/common.sh"

export OUT_DIR="${OUT_DIR:-${GC2026_ROOT}/output/submission_candidate_frame_gate_v2}"
export GATE_JSON="${GATE_JSON:-${SUBMISSION_ROOT}/config/gate_decision.json}"
export GEOMETRY_DIR="${GEOMETRY_DIR:-${GC2026_ROOT}/output/pdlts_finetune_geometry/light}"
export GEOMETRY_SECONDARY_DIR="${GEOMETRY_SECONDARY_DIR:-${GC2026_ROOT}/output/superpc_geometry/blend_cg}"
export UVG_CG_VERSION="${UVG_CG_VERSION:-v2}"
export SKIP_PDLTS="${SKIP_PDLTS:-0}"
export SKIP_SUPERPC="${SKIP_SUPERPC:-0}"

if [[ -z "${CG_LIST:-}" ]]; then
  CG_LIST="${GC2026_ROOT}/data/processed/all_cg_only_cgv2.txt"
fi
export CG_LIST

"${SRC_DIR}/download_pdlts.sh"
"${SRC_DIR}/download_pretrained.sh"

if [[ "$SKIP_PDLTS" != "1" ]]; then
  echo "[run.sh] Stage1 ft PD-LTS -> $GEOMETRY_DIR"
  bash "${SRC_DIR}/run_dual_gpu_pdlts.sh"
fi
if [[ "$SKIP_SUPERPC" != "1" ]]; then
  echo "[run.sh] Stage2 SuperPC blend_cg -> $GEOMETRY_SECONDARY_DIR"
  bash "${SRC_DIR}/run_dual_gpu_superpc.sh"
fi

echo "[run.sh] Stage3 frame_gate v2 hybrid -> $OUT_DIR"
"$PYTHON" "${SRC_DIR}/run_enh_refine_infer.py" \
  --cg-list "$CG_LIST" --out-dir "$OUT_DIR" \
  --refine-config "$GATE_JSON" \
  --geometry-dir "$GEOMETRY_DIR" \
  --geometry-secondary-dir "$GEOMETRY_SECONDARY_DIR" \
  --use-geometry-cache --require-geometry-cache

echo "[run.sh] DONE -> $OUT_DIR"
EOF
chmod +x "${ENH_DIR}/src/run.sh"

cat > "${ENH_DIR}/src/run_smoke.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SRC_DIR}/common.sh"
SMOKE_FRAMES="${SMOKE_FRAMES:-2}"
OUT_DIR="${OUT_DIR:-${GC2026_ROOT}/output/submission_smoke_frame_gate_v2}"
VAL_CG="${GC2026_ROOT}/data/processed/val_cg_only_official_cgv2.txt"
mkdir -p "$OUT_DIR"
head -n "$SMOKE_FRAMES" "$VAL_CG" > "$OUT_DIR/smoke_cg_list.txt"
export OUT_DIR CG_LIST="$OUT_DIR/smoke_cg_list.txt"
export GEOMETRY_DIR="${GEOMETRY_DIR:-$OUT_DIR/pdlts_geometry}"
export GEOMETRY_SECONDARY_DIR="${GEOMETRY_SECONDARY_DIR:-$OUT_DIR/superpc_geometry}"
export GATE_JSON="${SUBMISSION_ROOT}/config/gate_decision.json"
bash "${SRC_DIR}/run.sh"
echo "[run_smoke] DONE -> $OUT_DIR"
EOF
chmod +x "${ENH_DIR}/src/run_smoke.sh"

cat > "${ENH_DIR}/src/post_submission_candidate.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SRC_DIR}/common.sh"
OUT="${OUT_DIR:-${GC2026_ROOT}/output/submission_candidate_frame_gate_v2}"
GATE_JSON="${SUBMISSION_ROOT}/config/gate_decision.json"
VAL_PAIRS="${UVG_VAL_PAIRS_FILE}"
n=$(find "$OUT" -name '*.ply' 2>/dev/null | wc -l)
echo "[post] ply_count=$n"
"$PYTHON" "${SRC_DIR}/write_runtime_summary.py" --out-dir "$OUT" --team "GC2026 Team" || true
"$PYTHON" "${SRC_DIR}/make_submission.py" \
  --enhanced-dir "$OUT" --team "GC2026 Team" \
  --processing-track "Enhancement Only" \
  --title "UVG-CWI-DQPC GC2026 Enhancement Only frame_gate v2 hybrid" \
  --post-processing "$GATE_JSON" --cg-version "${UVG_CG_VERSION:-v2}" \
  --cg-source "official" \
  --data-split "official_val=TrumanShow,VictoryHeart,VirtualLife" \
  --pipeline-notes "CGv2 -> UVG-finetuned PD-LTS light -> SuperPC blend_cg secondary -> frame_gate v2 (primary anchor, CG-hole mask, max10pct fill)"
if [[ -f "$VAL_PAIRS" ]]; then
  "$PYTHON" "${SRC_DIR}/evaluate_gc_baseline_metrics.py" \
    --pairs-file "$VAL_PAIRS" --test-root "$OUT" --test-mode enh \
    --out-json "${OUT}/evaluation_gc_baseline_val565.json" --also-cg || true
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
# Environment setup (frame_gate v2 hybrid)

## Layout

```text
/workspace/                         ← GC2026_ROOT
  code/PD-LTS/                      ← git clone
  code/SuperPC/                     ← git clone
  models/superpc_pretrained/kitti360_com.pth
  submissions/GC2026_Team_EnhancementOnly/models/DenoiseFlow-light-UVG-finetune.ckpt
```

## Python

```bash
conda create -n superpc python=3.9 -y && conda activate superpc
pip install -r requirements.txt
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu128
bash src/setup_pdlts_deps.sh
```

### 3b. Optional: PD-LTS fine-tune dependencies

```bash
bash src/setup_pdlts_train.sh
```

Preset: `holefill_adaptive_frame_gate_v2` in `config/gate_config.json`.
EOF

cat > "${ENH_DIR}/README.md" <<'EOF'
# GC2026 Team — Enhancement Only (frame_gate v2 hybrid)

## Algorithm Name
UVG-finetuned PD-LTS light + frame-level SuperPC fill gate v2 (`holefill_adaptive_frame_gate_v2`)

## Algorithm Description
Official CG PLY (v2) → **PD-LTS light UVG finetune** (primary) → **always** snap 1 mm + fill 0.6 density on primary → **per-frame gate** decides SuperPC `blend_cg` hole fill (TrumanShow adaptive; VictoryHeart/VirtualLife skip SuperPC). KNN color from CG.

## Processing Track
**Enhancement Only**

## How to Run

```bash
export GC2026_ROOT=/path/to/workspace
cd submissions/GC2026_Team_EnhancementOnly
conda activate superpc
bash src/run.sh
```

Output: `$GC2026_ROOT/output/submission_candidate_frame_gate_v2/` (2155 ENH PLY).

Smoke: `bash src/run_smoke.sh`

### Training (optional — reproduce PD-LTS UVG fine-tune)

The submission includes a fine-tuned checkpoint (`models/DenoiseFlow-light-UVG-finetune.ckpt`).
To re-run fine-tuning on the UVG train split:

```bash
bash src/setup_pdlts_train.sh                          # one-time deps
GPUS=4 bash src/run_pdlts_finetune_uvg.sh train         # full training (20 epochs)
```

## Local validation (gc_baseline val565, 564 frames)
| Method | Chamfer (mm) |
|--------|-------------|
| ft PD-LTS + density (no SuperPC) | **14.883** |
| **frame_gate v2 (this package)** | **14.870** |
| CG baseline | 17.552 |

See `config/gate_decision.json` for full refine preset.
EOF

while IFS= read -r -d '' f; do python3 -m py_compile "$f"; done < <(find "${ENH_DIR}/src" -name '*.py' -print0)
bash -n "${ENH_DIR}/src/run.sh"
bash -n "${ENH_DIR}/src/run_smoke.sh"
echo "[build_frame_gate_v2] DONE $ENH_DIR"
