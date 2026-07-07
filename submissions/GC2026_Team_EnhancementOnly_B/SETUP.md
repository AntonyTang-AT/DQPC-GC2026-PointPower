# 组委会复现指南 — Enhancement Only (frame_gate v2)

本提交包 + 官方 UVG-CWI-DQPC 数据集即可完整复现 **推理**；若组委会提供训练集（CG+HE），也可复现 **PD-LTS UVG 微调**。

**数据目录详见 [`data/DATA_LAYOUT.md`](data/DATA_LAYOUT.md)**（全部使用相对 `$GC2026_ROOT` 的路径）。

---

## 1. 提交包内容

```
GC2026_Team_EnhancementOnly/
├── models/                          # 推理权重（已包含）
├── config/gate_decision.json
├── data/
│   ├── DATA_LAYOUT.md               # 数据集放置说明（相对路径）
│   └── generate_pair_lists.sh
└── src/                             # 推理 + 训练脚本
```

---

## 2. 组委会需自行准备的数据（相对 `$GC2026_ROOT`）

### 仅推理

```
data/raw/UVG-CWI-DQPC/<Sequence>/consumer-grade_capture_system/CG/15fps/*.ply
```

### PD-LTS 微调 / 评估（CG + HE）

```
data/raw/UVG-CWI-DQPC/<Sequence>/consumer-grade_capture_system/CG/15fps/*.ply
data/raw/UVG-CWI-DQPC/<Sequence>/high-end_capture_system/HE/15fps/*.ply
```

**Train / Val 序列名**由组委会在 `data/splits/split.json`（或见 `data/splits/README.md`）中定义，提交包不硬编码。

---

## 3. 目录结构（相对 `$GC2026_ROOT`）

```
./                          ← export GC2026_ROOT=./workspace 后即为根
data/raw/UVG-CWI-DQPC/      ← 组委会放入数据
data/processed/             ← generate_pair_lists.sh 生成
code/PD-LTS/                ← download_pdlts.sh
code/SuperPC/               ← download_pretrained.sh
code/Metric/                ← download_metric.sh（训练/评估）
output/                     ← 推理与训练输出
```

提交包解压位置任意，与 `GC2026_ROOT` 无关。

---

## 4. 环境

Ubuntu 22.04 · Python 3.9（conda `superpc`）· CUDA 12.8 · NVIDIA GPU

---

## 5. 基础安装

```bash
tar xzf GC2026_Team_EnhancementOnly.tar.gz
cd GC2026_Team_EnhancementOnly
export GC2026_ROOT=../workspace          # 含 data/raw/ 的目录

# 1) 复制 data/splits/split.json.example → data/splits/split.json 并填入组委会序列名
# 2) 生成索引
bash data/generate_pair_lists.sh

conda create -n superpc python=3.9 -y && conda activate superpc
pip install -r requirements.txt
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu128

bash src/download_pdlts.sh
bash src/download_pretrained.sh
bash src/setup_pdlts_deps.sh
```

---

## 6. 推理

PD-LTS 权重自动选择：

1. 若存在 `output/pdlts_finetune_uvg/run_*/DenoiseFlow-light-UVG-finetune.ckpt` → 用自训权重  
2. 否则 → 用包内 `models/DenoiseFlow-light-UVG-finetune.ckpt`

```bash
bash src/run_smoke.sh
export CG_LIST=$GC2026_ROOT/data/processed/all_cg_only_cgv2.txt
bash src/run.sh
```

输出：`output/submission_candidate_frame_gate_v2/`

---

## 7. PD-LTS 微调（可选，自适应 train 规模）

Train/val 序列名从 `data/splits/` 读取，帧数与 `patches_per_epoch` 随 pairs 文件自动缩放。

```bash
bash src/setup_pdlts_train.sh
bash src/run_pdlts_finetune_uvg.sh smoke          # 16 帧快速验证（已实测通过）
GPUS=4 bash src/run_pdlts_finetune_uvg.sh train   # patches/epoch 随 train 帧数缩放
```

训练输出写入 `output/pdlts_finetune_uvg/run_*/`；下次 `run.sh` 自动优先使用该 ckpt。

---

## 8. 环境变量

| 变量 | 说明 |
|------|------|
| `GC2026_ROOT` | 工作区根（相对/绝对均可） |
| `CG_LIST` | 全量推理 CG 列表 |
| `PDLTS_FINETUNE_CKPT` | 可选，强制指定 PD-LTS 权重路径 |
