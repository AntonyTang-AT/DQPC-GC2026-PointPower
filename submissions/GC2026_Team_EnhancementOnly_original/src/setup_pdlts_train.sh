#!/usr/bin/env bash
# PD-LTS fine-tune / training deps (extends setup_pdlts_deps.sh for inference).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
PDLTS="${GC2026_ROOT}/code/PD-LTS"

bash "${SCRIPT_DIR}/setup_pdlts_deps.sh"

# User should have already activated conda env per SETUP.md

echo "[pdlts-train] pytorch-lightning + tensorboard"
pip install -q 'pytorch-lightning>=2.0,<2.5' tensorboard

echo "[pdlts-train] build EMD CUDA extension"
cd "$PDLTS/metric/emd"
python setup.py install -q

echo "[pdlts-train] import smoke (TrainerModule + EMD + kaolin stub)"
cd "$PDLTS"
python - <<'PY'
import os, sys, types, torch
from pytorch3d.loss import chamfer_distance as p3d_cd

# Vendored kaolin lives under models/kaolin; stub metrics for loss.py
kaolin = types.ModuleType("kaolin")
km = types.ModuleType("kaolin.metrics")
kpc = types.ModuleType("kaolin.metrics.pointcloud")
kpc.chamfer_distance = p3d_cd
km.pointcloud = kpc
kaolin.metrics = km
for name, mod in [("kaolin", kaolin), ("kaolin.metrics", km), ("kaolin.metrics.pointcloud", kpc)]:
    sys.modules[name] = mod

sys.path.insert(0, os.path.join(os.getcwd(), "models"))
sys.path.insert(0, os.getcwd())
_old = torch.load
torch.load = lambda *a, **k: _old(*a, **{**k, "weights_only": False})

from models.model_light.train_deflow_score import TrainerModule, model_specific_args
from metric.loss import EarthMoverDistance1

cfg = model_specific_args().parse_args([])
m = TrainerModule(cfg)
print("[pdlts-train] TrainerModule OK", sum(p.numel() for p in m.network.parameters()))
PY

echo "[pdlts-train] ready. Smoke: bash src/run_pdlts_finetune_uvg.sh smoke"
