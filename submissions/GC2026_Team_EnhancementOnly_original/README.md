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
Official CG PLY (v2) → **PD-LTS light UVG finetune** (primary) → **always** snap 1 mm + fill 0.6 density on primary → **per-frame gate** decides SuperPC `blend_cg` hole fill (TrumanShow adaptive; VictoryHeart/VirtualLife skip SuperPC). KNN color from CG.

## Processing Track
**Enhancement Only**

## Hardware / Environment
- GPU: 4× NVIDIA RTX 5090 (32 GB each)
- CPU: x86_64 with AVX2
- OS: Ubuntu 22.04 LTS
- Python: 3.9 (conda env `superpc`)
- CUDA: 12.8

## Runtime
Total 2155 frames: ~5 h (PD-LTS light 2 GPU) + ~3 h (SuperPC blend_cg 2 GPU) + ~1 h (refine CPU). See `config/gate_decision.json` for preset details.

## How to Run

### 1. Set workspace root (must contain dataset)

```bash
export GC2026_ROOT=/workspace          # your dataset root
```

### 2. Generate pair lists

```bash
cd submissions/GC2026_Team_EnhancementOnly
bash data/generate_pair_lists.sh       # scans $GC2026_ROOT/data/raw/UVG-CWI-DQPC/
```

### 3. Set up environment and run

```bash
conda activate superpc                 # see SETUP.md for env creation
export CG_LIST=$GC2026_ROOT/data/processed/all_cg_only_cgv2.txt
bash src/run.sh
```

Output: `$GC2026_ROOT/output/submission_candidate_frame_gate_v2/` (2155 ENH PLY).

### Smoke test (2 frames)

```bash
bash src/run_smoke.sh
```

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
