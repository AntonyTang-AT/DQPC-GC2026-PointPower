# GC2026 Enhancement Only — 技术报告（合并版）

> **读者**：学长 / 答辩 / 论文  
> **日期**：2026-06-29  
> **指标口径**：官方 gc_baseline `chamfer_distance`（mm）  
> **数据索引**：见 [README.md](README.md)

---

## 1. 任务与结论

**任务**：官方 Consumer-Grade（CG）点云 → 增强 ENH，在 val565 上更接近 High-End（HE）。  
**提交**：Enhancement Only，`holefill_adaptive_frame_gate_v2`（ft PD-LTS + 逐帧 SuperPC 门控）。

**五条研发主线（val565 最优各一档）**：

| 主线 | 代表配置 | CD (mm) | vs CG (17.552) |
|------|----------|---------|----------------|
| 仅 SuperPC + 后处理 | filter_cg + snap 1 mm | 18.353 | −0.80 |
| 仅 PD-LTS（冻结权重）+ 后处理 | vh_snap0 | 17.440 | +0.112 |
| 仅 PD-LTS（UVG fine-tune）+ 后处理 | snap1 + fill0.6 density | 14.883 | +2.67 |
| 冻结 PD-LTS 最佳融合 | region_hybrid + density | 16.502 | +1.05 |
| **ft PD-LTS 最佳融合（提交）** | **frame_gate v2** | **14.870** | **+2.68** |

**叙事**：SuperPC 单独无法优于 CG → 转向 PD-LTS 去噪 + CG 锚定（snap/fill）→ UVG fine-tune 大幅拉升 → 谨慎引入 SuperPC 填洞（帧级 gate）略优于纯 ft。

---

## 2. 管线总览

```text
官方 CGv2
  ├─ [线 A] SuperPC kitti360 → filter/blend + snap/fill → ENH
  ├─ [线 B] PD-LTS 去噪（冻结或 UVG-FT）→ snap + density fill → ENH
  └─ [线 C] B 的几何 + SuperPC blend_cg 作 secondary → hybrid refine → ENH
         └─ 提交：恒 density 打底 + frame_fill_gate + VH/VL skip SuperPC
```

**不改网络结构**；贡献在推理编排、CG 保真融合、离散超参 gate。

---

## 3. 五条主线说明

### 3.1 仅 SuperPC（18.353 mm）

- **模型**：冻结 `kitti360_com.pth`，`use_vision=0`
- **后处理**：`filter_cg` 几何 + snap 1 mm（Phase2 最优；优于 `blend_cg` 20.58 mm）
- **判定**：gc_baseline 下仍 **劣于 CG**，研发放弃 SuperPC 单线提交
- **数据**：分序列汇总 CSV（逐帧 PLY 已清理）

### 3.2 仅 PD-LTS 未 fine-tune（17.440 mm）

- **模型**：`Denoiseflow-light-FBM.ckpt`（冻结）
- **后处理**：density-adaptive fill + snap；**val 最优** `vh_snap0`（仅 VictoryHeart snap=0）
- **对照**：全局统一 `density` 配置 17.504 mm（正式冻结权重提交线历史值）
- **raw 去噪 alone**：17.854 mm（劣于 CG），证明 refine 必要

### 3.3 仅 PD-LTS 已 fine-tune（14.883 mm）

- **模型**：`DenoiseFlow-light-UVG-finetune.ckpt`
- **后处理**：snap 1 mm + fill 0.6 density（与冻结线相同算子，权重域内适配）
- **角色**：无 SuperPC 的 **ft 基线**；融合对照锚点

### 3.4 未 fine-tune PD-LTS 最佳融合（16.502 mm）

- **配置**：`region_hybrid_pdlts_superpc_snap1_fill0.6_density`
- **思想**：冻结 PD-LTS 作 primary，SuperPC 仅在 **区域 mask** 内填洞
- **对比**：朴素 union hybrid 17.953 mm；region 掩码显著改善但仍不如纯 PD-LTS refine

### 3.5 已 fine-tune PD-LTS 最佳融合 — 提交（14.870 mm）

- **配置**：`holefill_adaptive_frame_gate_v2`
- **要点**：
  1. **恒** primary density refine（skip 不再输出裸 primary）
  2. 逐帧 `est_add_ratio` 门控是否加 SuperPC
  3. VictoryHeart / VirtualLife **序列级 skip** SuperPC
- **分序列**：TS −0.044 mm；VH/VL 与 ft 完全一致
- **相对 holefill lite（15.128）**：修复 v1 架构缺陷后首次优于 ft

---

## 4. 方法要点（论文 Method）

### 4.1 相对 PD-LTS

\[
\hat{P}_{\mathrm{ENH}} = \mathcal{R}_\phi\bigl(\mathcal{G}_\theta(P_{\mathrm{CG}}),\, P_{\mathrm{CG}}\bigr)
\]

- \(\mathcal{G}_\theta\)：PD-LTS 去噪（提交线经 UVG fine-tune）
- \(\mathcal{R}_\phi\)：**snap**（accuracy）+ **density-adaptive fill**（completeness），CG 点永不删除
- 与 PD-LTS 原文差异：在 **欧氏空间** 用 CG 硬锚定，而非仅潜空间去噪

### 4.2 相对 SuperPC

\[
\hat{P} = \mathcal{F}_\phi\bigl(\mathcal{G}^{\mathrm{SP}}_\theta(P_{\mathrm{CG}}),\, P_{\mathrm{CG}}\bigr)
\]

- \(\mathcal{G}^{\mathrm{SP}}_\theta\)：冻结扩散上采样
- \(\mathcal{F}_\phi\)：体素 merge / filter / 区域或帧级填洞
- val565 结论：即使最优 filter+snap，仍打不过 CG

### 4.3 frame_gate v2（提交）

```text
CG → ft PD-LTS → [always] snap1 + fill0.6 density
              → frame_fill_gate(est_add_ratio)
              → [optional] SuperPC blend_cg hole fill
              → KNN color from CG
```

---

## 5. 提交合规

| 项 | 状态 |
|----|------|
| README / src / requirements | ✅ |
| 不含 PLY / 数据集 | ✅ |
| Processing Track = Enhancement Only | ✅ |
| 2 帧冒烟 | ✅（见 submission_verify_report.json） |

组织方复现：

```bash
export GC2026_ROOT=/path/to/workspace
cd submissions/GC2026_Team_EnhancementOnly
bash src/run_smoke.sh   # 2 帧
bash src/run.sh         # 2155 帧
```

---

## 6. 数据文件说明

| 文件 | 内容 |
|------|------|
| `metrics/01_superpc_best_val565.csv` | SuperPC 最优；分序列 + 全局一行 |
| `metrics/02_pdlts_frozen_best_val565.csv` | vh_snap0；564 逐帧 |
| `metrics/03_pdlts_finetune_best_val565.csv` | ft density；564 逐帧 |
| `metrics/04_fusion_frozen_pdlts_best_val565.csv` | region_hybrid；564 逐帧 |
| `metrics/05_fusion_finetune_pdlts_best_val565.csv` | frame_gate v2；564 逐帧 |
| `val565_five_models.xlsx` | sheet1 汇总 + sheet2 CG + sheet3–7 各主线 |
| `config/submission_gate.json` | 提交 preset 完整 JSON |

---

## 7. 汇报提示

- **两套指标不可混用**：早期 SuperPC gate 用 `evaluate_uvg` cd_l1（~75 mm）；本文全部 gc_baseline（~17 mm / ~15 mm ft 线）
- **vh_snap0** 为 val 最优 ablation（VH snap=0），正式提交采用 **全局统一** gate
- **SuperPC** 在融合中有用（TS 稀疏帧），但必须 **门控** 避免 VH/VL 劣化

---

*由 `scripts/prepare_meeting_delivery.sh` 自动生成数据与图表；报告正文可随仓库版本手动修订。*
