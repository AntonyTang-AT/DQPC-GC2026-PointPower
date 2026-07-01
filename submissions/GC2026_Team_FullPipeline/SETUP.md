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
