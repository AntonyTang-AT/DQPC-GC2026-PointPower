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

Preset: `holefill_adaptive_frame_gate_v2` in `config/gate_config.json`.
