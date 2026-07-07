# DQPC-GC2026-PointPower

UVG Grand Challenge 2026 — **赛道一（UVG-CWI-DQPC）**  
团队 **PointPower** · Processing Track：**Enhancement Only**（官方 PR 已合并）

| 轨道 | 当前方案 | val565 Chamfer | 状态 |
|------|----------|----------------|------|
| **Enhancement Only（竞技提交）** | **PointPower** — PD-LTS UVG finetune + frame_gate v2 | **14.870 mm** | ✅ [UVG-CWI/submissions PR #2](https://github.com/UVG-CWI/submissions/pull/2) 已合并 |
| CG baseline | 官方 consumer-grade | 17.552 mm | 参照 |
| SuperPC 单线（旧） | blend_cg | 20.579 mm | 已放弃 |
| Full Pipeline N0 v2 | RGBD → Stage1 → SuperPC | 研发线 | 见 [`docs/N0_V2_RESULTS.md`](docs/N0_V2_RESULTS.md) |

---

## 快速入口

| 文档 | 路径 |
|------|------|
| **官方提交包（PointPower）** | [`submissions/PointPower/`](submissions/PointPower/) |
| **本地主包（同代码）** | [`submissions/GC2026_Team_EnhancementOnly/`](submissions/GC2026_Team_EnhancementOnly/) |
| **研发管线索引（思路 ↔ 脚本）** | [`docs/RESEARCH_PIPELINE.md`](docs/RESEARCH_PIPELINE.md) |
| **答辩 / 技术报告** | [`docs/meeting_delivery/REPORT.md`](docs/meeting_delivery/REPORT.md) |
| **Line B → frame_gate v2 演进** | [`docs/meeting_delivery/FUSION_EVOLUTION.md`](docs/meeting_delivery/FUSION_EVOLUTION.md) |
| **选型证据 JSON** | [`docs/meeting_delivery/evidence/`](docs/meeting_delivery/evidence/) |

---

## 当前进度（2026-07-08）

### Enhancement Only — 官方 gc_baseline（val565，564 帧）

| 方案 | Chamfer (mm) | vs CG | 角色 |
|------|-------------|-------|------|
| CG baseline | 17.552 | — | 参照 |
| ft PD-LTS + density（无 SuperPC） | 14.883 | +2.67 | ablation 锚点 |
| **PointPower frame_gate v2** | **14.870** | **+2.68** | **正式提交** |
| SuperPC blend_cg（旧） | 20.579 | −3.03 | 已放弃 |

证据：`docs/meeting_delivery/evidence/frame_gate_v2_val565_eval.json`

### 三阶段管线（对外叙述）

1. **Invertible latent denoising** — PD-LTS light UVG finetune  
2. **Spatial anchoring + density refine** — snap 1 mm + fill 0.6  
3. **Frame-level gated SuperPC** — 稀疏帧 fill；VH/VL 整序列 skip  

---

## 仓库结构

| 路径 | 用途 |
|------|------|
| [`submissions/PointPower/`](submissions/PointPower/) | **官方 GitHub 提交目录**（README + src + data + models） |
| [`submissions/GC2026_Team_EnhancementOnly/`](submissions/GC2026_Team_EnhancementOnly/) | 本地同步主包（含 A/B 变体见 [`submissions/SUBMISSION_VARIANTS.md`](submissions/SUBMISSION_VARIANTS.md)） |
| [`docs/RESEARCH_PIPELINE.md`](docs/RESEARCH_PIPELINE.md) | 研发思路 ↔ 脚本 ↔ 证据 |
| [`docs/meeting_delivery/`](docs/meeting_delivery/) | 报告、CSV、图表、证据 JSON |
| [`scripts/`](scripts/) | 推理、网格搜索、构建提交包、分析 |
| [`output/val_grid/gate_decision.json`](output/val_grid/gate_decision.json) | SuperPC 历史 gate |

**不入库（见 `.gitignore`）：** 工作区 `data/raw/`、`code/` 克隆、ENH `.ply`、`kitti360_com.pth`（运行时 `download_pretrained.sh` 下载）。

---

## 快速复现（Enhancement Only）

```bash
git clone https://github.com/AntonyTang-AT/DQPC-GC2026-PointPower.git
cd DQPC-GC2026-PointPower/submissions/PointPower

export GC2026_ROOT=../workspace    # 含 data/raw/UVG-CWI-DQPC/ 的工作区
bash data/generate_pair_lists.sh

conda create -n superpc python=3.9 -y && conda activate superpc
pip install -r requirements.txt
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu128
bash src/download_pdlts.sh && bash src/download_pretrained.sh && bash src/setup_pdlts_deps.sh

bash src/run_smoke.sh
export CG_LIST=$GC2026_ROOT/data/processed/all_cg_only_cgv2.txt
bash src/run.sh
bash src/post_submission_candidate.sh
```

---

## 关键脚本

| 脚本 | 用途 |
|------|------|
| `scripts/build_frame_gate_v2_submission.sh` | 构建 frame_gate v2 提交包 |
| `scripts/verify_submission_enhancement_only.sh` | 提交包冒烟 |
| `scripts/prepare_meeting_delivery.sh` | 生成交付文档与指标 |
| `scripts/run_pdlts_finetune_uvg.sh` | PD-LTS UVG 微调 |
| `scripts/check_integrity.sh` | 迁移后完整性检查 |

完整列表：[`scripts/README.md`](scripts/README.md) · 研发索引：[`docs/RESEARCH_PIPELINE.md`](docs/RESEARCH_PIPELINE.md)

---

## 硬件

4× NVIDIA RTX 5090（CUDA 12.8）；smoke 可用 1 GPU。全量 2155 帧约 9 h。

## 许可与引用

- 本仓库脚本：课题组 GC2026 研究使用  
- **SuperPC**：[sair-lab/SuperPC](https://github.com/sair-lab/SuperPC)  
- **PD-LTS**：[yanbiao1/PD-LTS](https://github.com/yanbiao1/PD-LTS)  
- **UVG 数据**：[ultravideo.fi](https://ultravideo.fi/UVG-CWI-DQPC/GC2026/) — 请勿二次分发
