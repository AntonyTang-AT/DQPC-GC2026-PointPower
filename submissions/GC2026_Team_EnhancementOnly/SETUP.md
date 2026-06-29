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
