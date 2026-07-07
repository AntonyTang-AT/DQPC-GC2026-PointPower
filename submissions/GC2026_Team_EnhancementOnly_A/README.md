# GC2026 Team — Enhancement Only (frame_gate v2 hybrid)

## Team Name
UVG-CWI-DQPC GC2026 Enhancement Only Submission

## Team Members
- Tianhua Qi (qitianhua@seu.edu.cn) — Southeast University
- Jiateng Liu (jiateng_liu@seu.edu.cn) — Southeast University
- Mingxin Tang (antonytang@hnu.edu.cn) — Hunan University
- Tianyi Zhang (t.zhang@seu.edu.cn) — Southeast University
- Yuan Zong (xhzongyuan@seu.edu.cn) — Southeast University
- Hengcan Shi (shihengcan@hnu.edu.cn) — Hunan University
- Yaonan Wang (yaonan@hnu.edu.cn) — Hunan University
- Wenming Zheng (wenming_zheng@seu.edu.cn) — Southeast University

## Algorithm Name
UVG-finetuned PD-LTS light + frame-level SuperPC fill gate v2 (`holefill_adaptive_frame_gate_v2`)

## Algorithm Description
Official CG PLY (v2) → **PD-LTS light UVG finetune** (primary) → snap 1 mm + fill 0.6 density → **per-frame gate** 决定是否用 SuperPC `blend_cg` 补洞（稀疏帧 full fill，低收益帧 skip）。颜色 KNN 迁移自 CG。

## Processing Track
**Enhancement Only**

## Hardware / Environment
- GPU: NVIDIA CUDA 12.8（测试：4× RTX 5090；smoke 可用 1 GPU）
- OS: Ubuntu 22.04 LTS
- Python: 3.9（conda env `superpc`）

## Runtime
2155 帧约 9 h（PD-LTS 2 GPU ~5 h + SuperPC 2 GPU ~3 h + refine CPU ~1 h）。

## Quick Start（组委会 · 推理）

数据放置见 [`data/DATA_LAYOUT.md`](data/DATA_LAYOUT.md)。**Train/Val 划分**：`data/splits/split.json`（见 `data/splits/README.md`）。  
完整说明见 [`SETUP.md`](SETUP.md)。

```bash
tar xzf GC2026_Team_EnhancementOnly.tar.gz && cd GC2026_Team_EnhancementOnly
export GC2026_ROOT=../workspace              # 含 data/raw/UVG-CWI-DQPC/
bash data/generate_pair_lists.sh
conda create -n superpc python=3.9 -y && conda activate superpc
pip install -r requirements.txt
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu128
bash src/download_pdlts.sh && bash src/download_pretrained.sh && bash src/setup_pdlts_deps.sh
bash src/run_smoke.sh
export CG_LIST=$GC2026_ROOT/data/processed/all_cg_only_cgv2.txt
bash src/run.sh
```

PD-LTS 权重：有自训 `output/pdlts_finetune_uvg/run_*/...` 则自动使用，否则用包内 `models/DenoiseFlow-light-UVG-finetune.ckpt`。

## PD-LTS 微调（组委会提供 train CG+HE 时）

```bash
bash src/setup_pdlts_train.sh
bash src/run_pdlts_finetune_uvg.sh smoke
GPUS=4 bash src/run_pdlts_finetune_uvg.sh train
bash src/install_finetuned_ckpt.sh
```

Train 集：9 序列 1590 帧（见 SETUP.md）；从 PD-LTS 官方 FBM 预训练初始化。

## Local Validation (val565, 564 frames)

| Method | Chamfer (mm) |
|--------|-------------|
| ft PD-LTS + density (no SuperPC) | 14.883 |
| **frame_gate v2 (this package)** | **14.870** |
| CG baseline | 17.552 |

Preset 详情：`config/gate_decision.json`。
