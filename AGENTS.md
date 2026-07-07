# GC2026 — Agent 操作指南（学长 / 新服务器接手）

> **项目根**：`/root/autodl-tmp/GC2026`（迁移后按实际路径设置 `GC2026_ROOT`）  
> **最后核查**：2026-06-29（目录结构 §2 增补）  
> **磁盘规模**：约 **1.2TB**（`data/` ~871GB + `output/` ~300GB + 其余）  
> **结构说明**：历史迭代导致 `output/` 与 `scripts/` 扁平堆积；§2 按 **ACTIVE / LEGACY / ARCHIVABLE** 标注，便于接手浏览

---

## 0. 30 秒：项目在做什么

**UVG Grand Challenge 2026 赛道一（UVG-CWI-DQPC）**：Consumer-Grade（CG）点云 → 增强 ENH，在 High-End（HE）真值下评测。

| 轨道 | 当前方案 | 竞技提交？ |
|------|----------|------------|
| **Enhancement Only** | **PD-LTS UVG-FT + density refine + frame_gate v2** | **是** → `submissions/GC2026_Team_EnhancementOnly/` |
| **Full Pipeline N0 v2** | RGBD → CWIPC Stage1 → SuperPC Stage2 | 否（研发）；源码在 `GC2026_Team_FullPipeline/` |

**学长汇报入口（优先读）**：[`docs/meeting_delivery/README.md`](docs/meeting_delivery/README.md)

| 文档 | 内容 |
|------|------|
| [REPORT.md](docs/meeting_delivery/REPORT.md) | 技术报告、五条主线、提交路线 §4 |
| [HIGHLIGHTS.md](docs/meeting_delivery/HIGHLIGHTS.md) | 论文式贡献点（ACM MM 体例 §1/2/4） |
| [HYPERPARAMETERS.md](docs/meeting_delivery/HYPERPARAMETERS.md) | 训练/推理超参 |
| [FUSION_EVOLUTION.md](docs/meeting_delivery/FUSION_EVOLUTION.md) | Line B → frame_gate v2 |
| [figures/compare3_cols_*.png](docs/meeting_delivery/figures/) | CG + 3 模型 + HE 配图 |

**val565 最优提交**：`holefill_adaptive_frame_gate_v2`，CD **14.870 mm**（564 帧，gc_baseline）  
快照：[`docs/meeting_delivery/config/submission_gate.json`](docs/meeting_delivery/config/submission_gate.json)

---

## 1. 接手后第一件事

```bash
cd /root/autodl-tmp/GC2026   # 或实际路径
bash scripts/check_integrity.sh
source scripts/env_setup.sh
python scripts/verify_superpc_ckpt.py
nvidia-smi && python -c "import torch; print(torch.__version__, torch.cuda.is_available())"
bash scripts/verify_submission_enhancement_only.sh   # 提交包冒烟（小样本）
python scripts/generate_status_report.py             # → output/status_report.md
```

---

## 2. 目录结构（为何显得乱 + 怎么找）

### 2.1 为何看起来乱

| 原因 | 表现 |
|------|------|
| 双线并行 | Enhancement Only 与 Full Pipeline N0 v2 共用根目录，产物都落在 `output/` |
| 实验迭代快 | val565 融合/ refine 各版本以**目录名**区分（`ft_val565_fusion/*`、`enh_refine_*`），未统一归档 |
| 脚本扁平 | `scripts/` 约 **287** 个 `.sh/.py` 同层堆放，靠**文件名前缀**区分阶段 |
| git 忽略大文件 | `data/`、`models/`、`output/` 不进 git，新人只能看本地树 |
| 历史包并存 | `submissions/` 下三套 Team 目录 + 根目录旧 `GC2026_Team/` manifest |

**接手原则**：先认 **四层**（输入 → 代码 → 运行 → 交付），再进 `output/` 查表；不要从根目录逐文件夹猜用途。

### 2.2 四层心智模型

```text
[输入]  data/ + models/          官方 CG/HE/bag、pair 索引、SuperPC/PD-LTS 权重
   ↓
[代码]  code/ + scripts/         上游克隆 + 编排/推理/评估/配图脚本
   ↓
[运行]  output/                  实验 PLY、gate JSON、日志、smoke（★ 最乱，见 §2.4）
   ↓
[交付]  docs/meeting_delivery/   学长汇报
        submissions/*            UVG 提交源码包
```

### 2.3 根目录树（按职责，非按磁盘大小）

图例：**★ ACTIVE** · **LEGACY** · **ARCHIVABLE** · **勿删**

```
GC2026/
├── AGENTS.md                         ← ★ 本文件（Agent / 学长入口）
├── README.md                         ← 人类总览（应与 meeting_delivery 同步）
│
├── docs/                             【文档层】
│   ├── meeting_delivery/             ← ★ ACTIVE 学长交付（报告/指标/配图/gate）
│   │   ├── README.md REPORT.md HIGHLIGHTS.md …
│   │   ├── config/submission_gate.json
│   │   ├── metrics/ figures/
│   │   └── …
│   ├── ARCHITECTURE.md               ← 双线架构
│   ├── N0_V2_RESULTS.md              ← Full Pipeline 结果
│   ├── CWIPC_NATIVE_PIPELINE.md      ← Stage1 + cwipc
│   ├── INTEGRITY.md / MIGRATION.md   ← 迁移验收（部分路径待同步 §10）
│   └── PROJECT_PROGRESS_REPORT.md
│
├── submissions/                      【UVG 提交源码 — 不含 PLY】
│   ├── GC2026_Team_EnhancementOnly/  ← ★ ACTIVE 竞技提交（frame_gate v2）
│   ├── GC2026_Team_FullPipeline/     ← Full Pipeline 研发提交包
│   └── GC2026_Team/                  ← LEGACY 旧 SuperPC 三 manifest 对照
│
├── scripts/                          【编排层 ~287 文件，见 §2.5】
│   ├── env_setup.sh check_integrity.sh
│   ├── submission_src/               ← 打进 tar 的源码片段
│   └── *.sh *.py
│
├── code/                             【上游克隆，gitignore】
│   ├── SuperPC/                      ← Stage2 / 融合支路
│   ├── PD-LTS/                       ← DenoiseFlow-light + UVG-FT
│   ├── Metric/ capturestudio/        ← 评估 / 采集辅助
│
├── models/                           【权重，gitignore ~500MB+】
│   ├── superpc_pretrained/           ← ★ 官方 kitti360/shapenet/tartanair
│   ├── superpc_finetuned/            ← 实验微调（若有）
│   └── logs/
│
├── data/                             【★ 勿删 ~871GB】
│   ├── raw/UVG-CWI-DQPC/             ← CGv2 / HE / RGBD bag
│   ├── processed/                    ← pair 列表、帧映射、rgbd_pairs
│   ├── intermediate/ GC_dataset/     ← 中间索引（按脚本使用）
│
├── output/                           【运行产物 ~300GB，见 §2.4 全表】
├── docker/                           ← 合规 Docker 构建上下文
├── pretrained/                       ← 零散预训练缓存（若有）
└── .ipynb_checkpoints/               ← ARCHIVABLE 可删
```

### 2.4 `output/` 全量分类（接手最常迷路处）

命名规律：`enh_refine_*` = PD-LTS 后处理 refine 实验；`ft_val565_*` = val565 融合线；`*smoke*` / `submission_smoke_*` = 小样本验证；`*candidate*` = 全量 ENH 候选（可能为空目录占位）。

| 路径 | 体量 | 标签 | 用途 |
|------|------|------|------|
| `ft_val565_fusion/holefill_adaptive_frame_gate_v2/` | ~数 GB | **★ ACTIVE** | **提交线** val565 全量 ENH；配图「Ours」 |
| `enh_refine_val565_selection/vh_snap0/` | ~数 GB | **★ ACTIVE** | 配图「PD-LTS」列 PLY |
| `meeting_delivery_viz/` | 168M | **★ ACTIVE** | 配图 SuperPC 几何缓存 |
| `pdlts_finetune_uvg/` | 23G | **★ ACTIVE** | UVG-FT 权重 + 全量/val 推理 |
| `enh_refine_p0_p1_p2/gate_decision.json` | 12K | **★ ACTIVE** | PD-LTS density refine gate |
| `full_pipeline_n0_v2_cg/` | 20G | **★ ACTIVE** | N0 v2 Stage1 自建 CG |
| `full_pipeline_n0_v2_candidate/` | 16G | **★ ACTIVE** | N0 v2 全量 ENH 候选 |
| `val_grid/gate_decision.json` | 12K | LEGACY | 旧 SuperPC gate（Full Pipeline 仍可能引用） |
| `submission_candidate/` | 20G | LEGACY | 旧 SuperPC Enhancement Only 2155 ENH |
| `pdlts_val565/` | 7.7G | LEGACY | 早期 PD-LTS val565（已被 fusion 线取代） |
| `enh_refine_val565_selection/`（除 vh_snap0） | ~78G | ARCHIVABLE | val565 refine 网格，仅保留 vh_snap0 |
| `ft_val565_fusion/`（除 frame_gate_v2） | ~48G | ARCHIVABLE | 融合 ablation 目录 |
| `enh_refine_p0_p1_p2/`（除 gate JSON） | ~52G | ARCHIVABLE | P0/P1/P2 PLY 树 |
| `adaptive_snap_study/` `enh_refine_phase2/` `enh_refine_snap_fill_grid/` | 8–20G | ARCHIVABLE | refine 扫参历史 |
| `submission_smoke_*` `*_smoke` `docker_official_val_smoke` | &lt;100M | ARCHIVABLE | 冒烟产物，验证后可删 |
| `*_candidate/`（空目录） | 0 | ARCHIVABLE | 占位符，可删 |
| `*.tar.gz`（submission 包） | 数 MB | 可选保留 | 已构建 tar，可重建 |
| `status_report.md/json` `cwipc_env.sh` | 小 | **保留** | 状态报告 / cwipc 环境 |
| 根下 `*.log` `*.json` 审计文件 | 小 | 按需 | Stage1 审计、合规评估日志 |

### 2.5 `scripts/` 怎么读（同层 287 文件）

不必全读。按**文件名前缀**定位：

| 前缀 / 模式 | 含义 | 示例 |
|-------------|------|------|
| `run_*` | 主入口（推理/管线/评估） | `run_full_n0_v2.sh`, `run_pdlts_full_submission.sh` |
| `build_*` | 打提交包 | `build_frame_gate_v2_submission.sh` |
| `verify_*` `check_*` | 验收 / 完整性 | `verify_submission_enhancement_only.sh` |
| `prepare_*` `render_*` | 学长交付 / 配图 | `prepare_meeting_delivery.sh`, `render_three_models_comparison.py` |
| `run_enh_refine_*` `run_ft_*` | PD-LTS refine / 融合实验 | 大量 val565 变体 |
| `run_stage1_*` `install_cwipc` | Full Pipeline Stage1 | `run_stage1_native_parallel.sh` |
| `watch_*` `monitor_*` | 长跑进度 | `watch_full_n0_v2.sh` |
| `post_*` | 后处理（manifest/eval/copy） | `post_submission_candidate.sh` |
| `evaluate_*` `compare_*` | 指标与对比 | `evaluate_gc_baseline_metrics.py` |

完整脚本索引仍见 [`scripts/README.md`](scripts/README.md)；**目录结构以本节为准**。

### 2.6 按任务找目录（导航表）

| 我想… | 去这里 |
|--------|--------|
| 给学长讲方案 / 写报告 | `docs/meeting_delivery/` |
| 改 UVG 提交代码 | `submissions/GC2026_Team_EnhancementOnly/src/` |
| 看提交 gate 快照 | `docs/meeting_delivery/config/submission_gate.json` |
| 重跑 compare3 配图 | `scripts/run_meeting_delivery_figures.sh`；PLY 依赖 §2.4 ACTIVE 三路径 |
| 找 frame_gate v2 全量 ENH | `output/ft_val565_fusion/holefill_adaptive_frame_gate_v2/` |
| 找 PD-LTS UVG-FT 权重 | `output/pdlts_finetune_uvg/` |
| 找官方 CG/HE | `data/raw/UVG-CWI-DQPC/` |
| 找 pair / 帧列表 | `data/processed/` |
| 跑 Full Pipeline N0 v2 | `scripts/run_full_n0_v2.sh` → 产物 `output/full_pipeline_n0_v2_*` |
| 查旧 SuperPC 2155 结果 | LEGACY：`output/submission_candidate/` |
| 清理磁盘 | 只动 §2.4 **ARCHIVABLE**；删前对照 §2.7「切勿删除」 |

### 2.7 切勿删除 / 可清理（汇总）

#### 切勿删除（除非整盘迁移归档）

| 路径 | 原因 |
|------|------|
| `data/raw/`、`data/processed/` | 官方数据与索引 |
| `models/superpc_pretrained/` | SuperPC / 融合支路权重 |
| `code/SuperPC/`、`code/PD-LTS/` | 上游代码 |
| `submissions/GC2026_Team_EnhancementOnly/` | **竞技提交源码** |
| `docs/meeting_delivery/` | 学长汇报交付 |
| `output/pdlts_finetune_uvg/` | UVG fine-tune 权重 |
| `output/ft_val565_fusion/holefill_adaptive_frame_gate_v2/` | 提交线 val565 全量 ENH + 配图依赖 |
| `output/enh_refine_val565_selection/vh_snap0/` | 配图 PD-LTS 列依赖 |
| `output/meeting_delivery_viz/` | 配图 SuperPC 几何缓存 |
| `output/enh_refine_p0_p1_p2/gate_decision.json` | PD-LTS density gate |
| `output/full_pipeline_n0_v2_*` | N0 v2 全量产物 |
| `output/val_grid/gate_decision.json` | SuperPC 历史 gate（Full Pipeline 仍可能引用） |

#### 可清理候选（删除前需人工确认；约 **~200GB+**）

| 优先级 | 目标 | 约计 |
|--------|------|------|
| P0 | `.ipynb_checkpoints/`、`scripts/__pycache__/`、空 `*_candidate/`、smoke 目录 | ~0.5GB |
| P1 | `enh_refine_val565_selection/*` 除 `vh_snap0/` | ~78GB |
| P1 | `ft_val565_fusion/*` 除 `holefill_adaptive_frame_gate_v2/` | ~48GB |
| P1 | `enh_refine_p0_p1_p2/*` 除 `gate_decision.json` | ~52GB |
| P2 | `adaptive_snap_study/`、`enh_refine_phase2/`、`enh_refine_snap_fill_grid/`、`pdlts_val565/` | ~40GB |
| P2 | LEGACY `submission_candidate/`（若不再需要旧 SuperPC 2155 对照） | ~20GB |

清理前运行 `bash scripts/check_integrity.sh`；配图/提交依赖路径见 §2.4 **ACTIVE** 行。

---

## 3. 两套 Python 环境

| 用途 | 环境 | 激活 |
|------|------|------|
| SuperPC / PD-LTS / 评估 / 配图 | conda **`superpc`** (Py3.9) | `source scripts/env_setup.sh` |
| cwipc / bag 回放 / Stage1 | 系统 Py3.12 + deb wheels | `source output/cwipc_env.sh`（若已安装） |

要点：RTX 5090 需 `torch==2.8.0+cu128`；升级后 `bash scripts/rebuild_extensions.sh`。  
cwipc 与 conda 的 libstdc++ 冲突 → `cwipc_env.sh` 内 `LD_PRELOAD` 系统库。

**Full Pipeline 阻塞项**（若需重跑 Stage1）：`librealsense2.so.2.56`、`rgbd_pairs.txt` — 见 `docs/INTEGRITY.md`。

---

## 4. 脚本入口（Agent 常用）

完整列表见 [`scripts/README.md`](scripts/README.md)。以下为高频入口：

### Enhancement Only（竞技）

| 命令 | 作用 |
|------|------|
| `bash scripts/build_frame_gate_v2_submission.sh` | 构建 frame_gate v2 提交包 |
| `bash scripts/build_pdlts_density_submission.sh` | 构建纯 PD-LTS density 包（ablation） |
| `bash scripts/verify_submission_enhancement_only.sh` | 提交包冒烟 |
| `bash scripts/run_pdlts_full_submission.sh` | 2155 帧 PD-LTS 全量推理 |
| `python scripts/run_enh_refine_infer.py` | 批量 enh refine |
| `bash scripts/run_official_eval_val565.sh` | gc_baseline 评估 |

### 配图 / 学长交付

| 命令 | 作用 |
|------|------|
| `bash scripts/prepare_meeting_delivery.sh` | 重建 `docs/meeting_delivery/` |
| `bash scripts/run_meeting_delivery_figures.sh` | 柱状图 + 框架图 + compare3 配图 |
| `python scripts/render_three_models_comparison.py` | 仅 compare3 五列图 |
| `python scripts/render_model_framework_diagram.py` | 提交框架图 |

### Full Pipeline N0 v2

| 命令 | 作用 |
|------|------|
| `bash scripts/run_full_n0_v2.sh` | 全量编排 Stage1→SuperPC→Post |
| `bash scripts/watch_full_n0_v2.sh` | 进度仪表盘 |
| `bash scripts/install_cwipc.sh` | librealsense + cwipc（耗时） |

### 维护

| 命令 | 作用 |
|------|------|
| `bash scripts/check_integrity.sh` | 迁移验收 |
| `bash scripts/migrate_to_new_server.sh` | rsync 迁移 |
| `python scripts/generate_status_report.py` | 状态报告 |

**已废弃 wrapper**（可忽略）：`run_zoom_figures.sh`、`run_paper_figures.sh` → 转发到 `run_meeting_figures.sh`。

---

## 5. Enhancement Only 管线（提交线 frame_gate v2）

```text
官方 CGv2 PLY
  → PD-LTS DenoiseFlow-light（UVG-FT 权重，epoch 19）
  → Primary density refine（snap 1.0 mm → fill 0.6 mm density_adaptive）  【每帧必做】
  → Frame fill gate（est_add_ratio → skip / lite / full；VH/VL 序列级 skip SuperPC）
  → [可选] SuperPC secondary 洞区 merge（fill_before_snap）
  → Post-SOR adaptive + KNN 颜色自 CG
  → ENH PLY
```

**不是**「先 fill 再 denoise」：神经网络去噪 **始终在最前**。  
SuperPC 单线仍 **劣于 CG**（18.35 mm），仅作门控填洞支路。

---

## 6. 关键数值（val565，gc_baseline）

| 配置 | CD (mm) |
|------|---------|
| CG baseline | 17.552 |
| SuperPC only | 18.353 |
| PD-LTS frozen | 17.440 |
| **ft PD-LTS only** | **14.883** |
| region hybrid (frozen) | 16.502 |
| **frame_gate v2（提交）** | **14.870** |

CSV / Excel：`docs/meeting_delivery/metrics/`、`val565_five_models.xlsx`

---

## 7. Agent 行为约定

1. **改代码前**：`source scripts/env_setup.sh`，确认 `GC2026_ROOT`。
2. **竞技提交**：只改 `submissions/GC2026_Team_EnhancementOnly/`；PLY 不进 git。
3. **不要误删** §2「切勿删除」列表；删 `output/` 大目录前对照 §2 清理候选。
4. **配图脚本**依赖 `output/ft_val565_fusion/.../holefill_adaptive_frame_gate_v2/` 等路径，删 PLY 前改脚本或保留子目录。
5. **评估**：优先 `evaluate_gc_baseline_metrics.py`（与组织方对齐）；CPU 评估避免多进程爆内存。
6. **文档**：学长可见内容以 `docs/meeting_delivery/` 为准；根 `README.md` 与之一致。

---

## 8. 迁移

- 脚本：`scripts/migrate_to_new_server.sh` + `scripts/migrate_exclude.txt`
- 步骤：`docs/MIGRATION.md`
- 迁移后需新机重装：GPU 驱动验证、librealsense、cwipc Py3.12 包（不随 rsync 自动带上）

---

## 9. 外部依赖

| 组件 | 来源 |
|------|------|
| SuperPC | https://github.com/sair-lab/SuperPC → `code/SuperPC` |
| PD-LTS | `code/PD-LTS` |
| cwipc | https://github.com/cwi-dis/cwipc v7.7.5 |
| librealsense | v2.56.5 |
| UVG 数据 | https://ultravideo.fi/UVG-CWI-DQPC/GC2026/ |
| SuperPC 权重 | `scripts/download_pretrained.sh` |

---

## 10. 文档与 AGENTS.md 已知过时项（待 INTEGRITY 同步）

以下在旧版 `INTEGRITY.md` / 旧 AGENTS 中出现，**当前仓库已变化**：

| 旧描述 | 现状 |
|--------|------|
| 主提交 `submissions/GC2026_Team/` | → **`GC2026_Team_EnhancementOnly/`** |
| Enhancement 主线 SuperPC blend_cg | → **PD-LTS + frame_gate v2** |
| `output/val_grid/` ~75GB | → 仅 **gate JSON**（~12KB） |
| `output/full_pipeline_candidate/` | → **`full_pipeline_n0_v2_candidate/`** |
| `output/gpu_pending.sh`、`cwipc_install_cache/` | 当前不存在 |
| 脚本「71 个」 | 实际 **~287 个** |

刷新状态：`python scripts/generate_status_report.py`
