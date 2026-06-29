#!/usr/bin/env bash
# Install PD-LTS inference deps into the existing superpc conda env (RTX 5090 / torch 2.8).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PDLTS="$ROOT/code/PD-LTS"

source /root/miniconda3/etc/profile.d/conda.sh
conda activate superpc

echo "[pdlts] pip deps (use default mirror; do NOT enable network_turbo for pip)"
pip install -q ninja scikit-learn fvcore iopath
pip install -q torch-cluster -f https://data.pyg.org/whl/torch-2.8.0+cu128.html
pip install -q --extra-index-url https://miropsota.github.io/torch_packages_builder \
  "pytorch3d==0.7.8+pt2.8.0cu128"

echo "[pdlts] build chamfer3D extension"
cd "$PDLTS/metric/PyTorchCD/chamfer3D"
python setup.py install -q

echo "[pdlts] patch pila.cu for torch 2.8 (scalar_type)"
for f in "$PDLTS/models/layers/base/pila.cu" "$PDLTS/modules/base/pila.cu"; do
  if grep -q 'x\.type()' "$f" 2>/dev/null; then
    sed -i 's/x\.type()/x.scalar_type()/g' "$f"
  fi
done

echo "[pdlts] smoke import"
cd "$PDLTS"
python - <<'PY'
import os, sys, types, torch
from pytorch3d.loss import chamfer_distance as cd
kaolin = types.ModuleType('kaolin'); km = types.ModuleType('kaolin.metrics'); kpc = types.ModuleType('kaolin.metrics.pointcloud')
kpc.chamfer_distance = cd; km.pointcloud = kpc; kaolin.metrics = km
for n,m in [('kaolin',kaolin),('kaolin.metrics',km),('kaolin.metrics.pointcloud',kpc)]: sys.modules[n]=m
sys.path.insert(0, os.getcwd())
_old = torch.load
torch.load = lambda *a, **k: _old(*a, **{**k, 'weights_only': False})
from models.model_light.denoise import get_denoise_net
net = get_denoise_net('product/ckpt/Denoiseflow-light-FBM.ckpt')
print('OK', type(net).__name__)
PY

echo "[pdlts] ready. Run: python scripts/run_pdlts_infer.py --cg-list ... --out-dir ..."
