# GC2026 Enhancement Only — 总思路与提示报告

> **读者**：学长 / 答辩汇报 / 论文撰写  
> **日期**：2026-06-29  
> **正式提交方案**：`pdlts_light_snap1_fill0.6_density`（PD-LTS + 几何 refine）  
> **官方 val565 指标**：`chamfer_distance = (accuracy + completeness) / 2`（mm），对齐矩阵后与 HE 比较（与 `ACMMM26_GC_baseline.csv` 同口径）

---

## 0. 一句话结论

我们在 **冻结预训练权重、零 UVG fine-tune** 的前提下，先走 **SuperPC 上采样 + CG 融合** 线完成全量工程与早期 gate；在切换到 **官方对齐 Chamfer** 评估后发现 SuperPC **无法优于官方 CG**；随后转向 **PD-LTS 去噪 + snap/fill 几何锚定**，在 val565 上 **首次稳定优于 CG（+0.048 mm）**。竞技提交采用 **全局统一超参** 的 density 方案，**不采用** 仅在 val 上有效的 `vh_snap0` 序列特例。

---

## 1. 针对比赛要求，为什么一开始选择 SuperPC？

### 1.1 比赛任务是什么

UVG GC2026 **赛道一（UVG-CWI-DQPC）** 的 **Enhancement Only** 轨道要求：

| 约束 | 含义 |
|------|------|
| 输入 | 官方 Consumer-Grade（CG）`.ply` 点云（v2，15 fps） |
| 输出 | 增强后的 ENH `.ply`，坐标系与 CG 一致 |
| 提交物 | **源码包**（组织方在官方输入上复现），不含 PLY |
| 目标 | ENH 在官方指标下更接近 High-End（HE）参考 |

任务本质是：**在不重新采集的前提下，把消费级点云「变干净、变密、变准」**。

### 1.2 为什么 SuperPC 是合理的第一选择

| 理由 | 说明 |
|------|------|
| **任务匹配** | SuperPC 是公开的点云 **上采样 / 生成** 模型，天然面向「从稀疏/噪声点云恢复更完整几何」 |
| **零训练成本** | 提供 Model Zoo（`kitti360_com.pth` 等），**无需在 UVG 上 fine-tune** 即可跑通 |
| **工程成熟** | 上游仓库完整、社区有先例；适合快速搭 Enhancement Only 全量管线（2155 帧） |
| **早期 gate 有效** | 在内部 val362 子集上，用 `evaluate_uvg` 的 **cd_l1**（~48–75 mm 量级）做网格搜索：`kitti360` + `blend_cg` + voxel 3 mm 相对 CG **改善约 +11 mm**（见 `docs/meeting_delivery/gate_snapshots/superpc_gate_decision.json`；运行时 `output/val_grid/gate_decision.json`） |
| **与 Full Pipeline 统一** | 同一 SuperPC 模块可接在 RGBD→Stage1 之后，便于双线研发 |

因此，**SuperPC 不是随意选型**，而是「增强任务 + 免训练 + 快速全量」下的 **理性首发方案**。

### 1.3 需要区分的两套指标（汇报时务必说清）

| 指标 | 典型数值 | 用途 |
|------|----------|------|
| `evaluate_uvg` **cd_l1**（子采样 n=20k） | CG ~86 mm → ENH ~75 mm | **早期 SuperPC gate**、全量 2155 跑批监控 |
| **gc_baseline** `chamfer_distance`（全点对齐 HE） | CG **17.552 mm** | **官方对标**、论文 Table、当前提交决策 |

两套指标 **不可横比**。后期发现：在 cd_l1 上领先的 SuperPC `blend_cg`，在 **官方 gc_baseline 上反而差于 CG（20.58 mm）**——这是换线的直接触发点。

---

## 2. SuperPC 线：做了哪些调整？哪些有效？最终结果？

### 2.1 我们没有改什么

- SuperPC **网络结构与权重**：完全冻结，选用 `kitti360_com.pth`
- **未在 UVG 上训练**；`use_vision=0`，未启用视觉条件分支

### 2.2 我们加了什么（推理层 / 后处理）

```text
官方 CG PLY
    → SuperPC 推理（冻结 kitti360）
    → output_mode 选择（blend_cg / filter_cg 等）
    → 体素融合 / SOR / snap / fill（Enh Refine 管线）
    → KNN 颜色从 CG 迁移
    → ENH PLY
```

| 模块 | 作用 | 改权重？ |
|------|------|----------|
| `blend_cg` | 模型输出与输入 CG **体素合并**，保留消费级几何 | 否 |
| KNN 上色 | 增强点颜色回传自 CG | 否 |
| val 网格 gate | checkpoint、voxel、per-seq 离散超参 | 否 |
| `filter_cg` | 以 CG 为几何基底 + 离群过滤 | 否 |
| snap / fill | 将预测点锚回 CG / 补洞 | 否 |

实现：`scripts/run_superpc_infer.py`、`scripts/uvg_io.py`、`scripts/enh_refine_pipeline.py`。

### 2.3 尝试与结果（官方 val565，564 帧）

| 实验 | chamfer (mm) | vs CG (17.552) | 判定 |
|------|-------------|----------------|------|
| **CG baseline** | 17.552 | — | 参照 |
| `superpc_filter_snap1.0`（Phase2 最优） | **18.353** | **−0.80** | ❌ 仍劣于 CG |
| `superpc_filter_post25` | 18.710 | −1.16 | ❌ |
| `superpc_filter_snap1_fill0.6` | 17.552 | 0（持平） | △ aggregate 持平，无净收益 |
| **`blend_cg`（旧提交线，全量 2155）** | **20.579** | **−3.03** | ❌ 官方口径下明显变差 |
| `hybrid_pdlts_superpc` + density | 17.953 | −0.40 | ❌ 混合仍不如纯 PD-LTS |

**有效（在特定口径下）**：

- `blend_cg` + gate：在 **cd_l1 / val362** 上选出最优，支撑了早期全量 2155 推理与工程交付
- `filter_cg` 系：在 gc_baseline 上把 SuperPC 线从 20+ mm **拉到 ~18.35 mm**，但仍 **打不过 CG**

**无效（在官方 gc_baseline 目标下）**：

- 纯上采样 + `blend_cg`：**几何膨胀但不对齐 HE**，官方 Chamfer 变差
- SuperPC + snap 1 mm alone：与 `filter_cg` aggregate **相同**（18.35），snap 未带来额外收益
- 后处理 SOR（`post25`）：更差
- PD-LTS 与 SuperPC **混合 fill**：17.95–18.20 mm，不如纯 PD-LTS refine

### 2.4 SuperPC 线小结

> SuperPC 完成了「能跑、能 gate、能全量」的工程目标，但在 **组织方对齐 Chamfer** 下，**最好一档（~18.35 mm）仍劣于不增强的 CG（17.55 mm）**。继续堆 SuperPC 后处理收益递减，研发重心转向 **去噪先验 + CG 锚定**。

详见：`SUPERPC_VAL565_RECORD.md`、Excel **sheet3 / sheet7**。

---

## 3. 为什么更换模型？PD-LTS 优势、后处理与结果

### 3.1 换线原因

| 问题（SuperPC） | PD-LTS 线的应对 |
|-----------------|-----------------|
| 生成式上采样易引入 **与 HE 不一致的新几何** | **去噪**模型：在 CG 流形附近收缩噪声，而非「造点」 |
| 官方指标惩罚 **accuracy + completeness 双向误差** | 去噪 + **snap 贴回 CG** 更好控制双向距离 |
| `blend_cg` 保真仍不足（20.58 mm） | **显式几何锚定**（snap / fill / density-adaptive） |

### 3.2 PD-LTS 模型优势（相对 SuperPC，在本任务上）

| 维度 | PD-LTS DenoiseFlow-light |
|------|--------------------------|
| 任务对齐 | **去噪**而非补全，更贴合「CG 已有点，只需清理」 |
| 计算 | light 权重，大点云可分块（>50k） |
| 与 CG 关系 | 输出仍接近输入拓扑，便于后续 **无训练 refine** |
| 权重 | `Denoiseflow-light-FBM.ckpt`，**零 UVG fine-tune** |

### 3.3 我们的后处理（Enh Refine，无神经网络）

```text
官方 CG PLY
    → PD-LTS light 去噪（冻结）
    → KNN 上色
    → snap（默认 1.0 mm）：将点拉向去噪几何 / CG 锚点
    → fill（0.6 mm base）+ density_adaptive：按局部密度自适应补洞
    → ENH PLY
```

核心文件：`scripts/run_pdlts_infer.py`、`scripts/enh_refine_pipeline.py`；gate 快照：`docs/meeting_delivery/gate_snapshots/pdlts_gate_decision.json`（运行时 `output/enh_refine_p0_p1_p2/gate_decision.json`）。

### 3.4 尝试与结果（官方 val565）

| 实验 | chamfer (mm) | vs CG | 判定 |
|------|-------------|-------|------|
| **pdlts_raw**（仅去噪，无 refine） | **17.854** | **−0.30** | ❌ 证明 refine **必要** |
| `pdlts_light_snap1.0`（仅 snap） | 17.940 | −0.39 | ❌ |
| `pdlts_light_snap1_fill0.6` | 17.506 | +0.045 | ✅ 首次优于 CG |
| **`pdlts_light_snap1_fill0.6_density`** | **17.504** | **+0.048** | ✅ **提交方案** |
| `pdlts_light_snap1_fill0.6_post25` | 17.917 | −0.36 | ❌ 后 SOR 有害 |
| `p1_pdlts_heavy` | 17.954 | −0.40 | ❌ heavy 无益 |
| `density_temporal_w3/w5` | 17.504 | +0.048 | △ 与 density 相同，无增益 |
| `fp_migrated_pre25_density` | 17.598 | −0.05 | ❌ |
| **`vh_snap0`**（VH 序列 snap=0） | **17.440** | **+0.112** | ✅ val 最优，**不进提交**（见 §4） |

**有效**：

- **snap + fill** 组合：从 raw 17.85 → 17.51 mm
- **density_adaptive fill**：在 fixed fill 基础上再 +0.002 mm，且更稳
- **全局统一超参**：三序列均可获益或持平

**无效**：

- 单独 PD-LTS 去噪（不如 CG）
- 仅 snap、后 SOR、heavy 模型、时序窗口、SuperPC 混合、从 Full Pipeline 迁移的 pre-SOR

### 3.5 PD-LTS 线小结

> **PD-LTS 提供几何先验，refine 提供 CG 保真**；二者缺一不可。提交配置 `pdlts_light_snap1_fill0.6_density` 在 val565 上 **稳定优于 CG +0.048 mm**，且 **无序列特例**。

---

## 4. 为什么没有选择 `vh_snap0`？

### 4.1 它是什么

在 density 基线上，**仅对 VictoryHeart 序列** 将 `snap_mm` 覆盖为 **0**（`vh_configs/snap0_per_seq.json`），其余序列仍为 snap=1。

### 4.2 结果上为什么更好却不提交

| 序列 | CG | density | vh_snap0 | vh_snap0 相对 density |
|------|-----|---------|----------|------------------------|
| TrumanShow | 19.337 | 19.268 | 19.268 | **无变化** |
| VictoryHeart | 16.214 | 16.207 | **16.024** | **−0.18 mm（唯一收益来源）** |
| VirtualLife | 17.338 | 17.268 | 17.268 | **无变化** |
| **全局均值** | 17.552 | 17.504 | **17.440** | +0.064 mm vs density |

全局 +0.112 mm vs CG 的提升 **几乎全部来自 VictoryHeart 一条序列的手工规则**。

### 4.3 意义上为什么不提交

| 原因 | 说明 |
|------|------|
| **泛化风险** | 隐藏测试集含 train 序列；对 val 中某一序列写死 `snap=0` 属于 **验证集特例**，无法保证 test 上同样最优 |
| **可复现与合规** | 组织方期望 **单一、可声明的算法**；per-sequence JSON 需额外解释「为何 VH 特殊」 |
| **规则化替代失败** | 我们尝试过 **自适应 snap**（按 inlier / geometry_close 规则），**无法复现** vh_snap0 在 VH 上的收益（`output/adaptive_snap_study/`） |
| **收益 / 风险不成比例** | 相对 density 仅多 **0.064 mm**，却引入 **序列相关决策**；竞技提交优先 **规则简单、可辩护** |

**论文中的位置**：`vh_snap0` 作为 **ablation / 上界**，写入 Excel sheet4，证明「若允许 val 微调还可再好一点」，但 **正式 `run.sh` 使用全局 density**。

---

## 5. 总思路、框架与效果

### 5.1 研发时间线（简图）

```text
2026-06 上旬   SuperPC 全量 + val_grid gate（cd_l1）
      ↓
2026-06 中旬   切换官方 gc_baseline 评估 → SuperPC blend_cg 劣于 CG
      ↓
2026-06-27     Phase2：SuperPC filter 系 vs PD-LTS snap/fill → PD-LTS 胜出
      ↓
2026-06-27+    P0/P1/P2 网格 → density_adaptive 最优
      ↓
2026-06-29     val565_selection：vh_snap0 上界 → 提交仍选 density
      ↓
当前           提交包：GC2026_Team_EnhancementOnly（PD-LTS density）
```

### 5.2 最终框架（提交版）

```mermaid
flowchart LR
  CG[官方 CG PLY v2] --> PDLTS[PD-LTS light 去噪<br/>冻结 FBM.ckpt]
  PDLTS --> KNN[KNN 颜色迁移]
  KNN --> SNAP[snap 1.0 mm]
  SNAP --> FILL[density-adaptive fill<br/>base 0.6 mm]
  FILL --> ENH[ENH PLY 输出]
```

**符号化**（论文 Method）：\(\hat P = \mathcal{R}_\phi(\mathcal{G}_\theta(P_{CG}), P_{CG})\)，\(\theta\) 冻结，仅 \(\phi\) 在 val 上网格搜索。

### 5.3 效果一览（官方 val565，564 帧）

| 阶段 | 代表配置 | chamfer (mm) | vs CG |
|------|----------|-------------|-------|
| 参照 | CG baseline | 17.552 | — |
| SuperPC 旧线 | blend_cg | 20.579 | −3.03 |
| SuperPC 最优 | filter + snap1 | 18.353 | −0.80 |
| PD-LTS 无 refine | raw | 17.854 | −0.30 |
| **提交** | **density** | **17.504** | **+0.048** |
| ablation 上界 | vh_snap0 | 17.440 | +0.112 |

### 5.4 方法贡献（可写进论文）

1. **Training-free**：UVG 上零 fine-tune，仅 test-time 管线配置。  
2. **系统对比**：同一官方指标下，扩散上采样（SuperPC）vs 去噪先验（PD-LTS）。  
3. **CG-preserving refine**：snap + density-adaptive fill 作为 **无训练几何后处理**。  
4. **诚实的 ablation**：vh_snap0 展示 val 微调上界，并说明为何不用于提交。

### 5.5 不宜使用的表述

- ❌「在 UVG 上 fine-tuned SuperPC / PD-LTS」  
- ❌「提出了新的点云网络」  
- ❌ 把 cd_l1（~75 mm）与 gc_baseline（~17.5 mm）混为同一指标  
- ❌ 把 pdlts_density 与 SuperPC blend_cg 的 20+ mm 数字并列而不注明口径

---

## 6. 表格意义与提交包待填项

### 6.1 Excel：`val565_gc_baseline_metrics.xlsx`

**详细字段说明**：`VAL565_METRICS_XLSX.md`

| Sheet | 数据含义 | 汇报用途 |
|-------|----------|----------|
| **sheet1_summary** | 各模型全局 + 分序列均值 | 答辩一页表 / 论文 Table 1 |
| **sheet1_meta** | 指标口径、生成时间 | 防止指标混淆 |
| **sheet2_cg_baseline** | 官方 CG vs HE，564 逐帧 | 下限参照 |
| **sheet3_superpc_blend_cg** | 旧 SuperPC 提交线逐帧 | 说明为何放弃 SuperPC |
| **sheet4_pdlts_vh_snap0** | density + VH snap=0 逐帧 | ablation 上界，**非提交** |
| **sheet5_pdlts_density** | **当前提交方案**逐帧 | 正式方法成绩 |
| **sheet6_pdlts_raw** | 仅 PD-LTS 去噪逐帧 | 量化 refine 贡献 |
| **sheet7_superpc_filter_snap1** | SuperPC Phase2 最优（分序列汇总 4 行） | SuperPC 历史上限对照 |

**推荐阅读顺序**：sheet2 → sheet6 → sheet7 → sheet3 → sheet5 → sheet4。

**源 CSV**：`docs/meeting_delivery/metrics/01–05_*.csv`。

### 6.2 提交包：`submissions/GC2026_Team_EnhancementOnly/`

| 路径 | 状态 | 提交前待办 |
|------|------|------------|
| **README.md → Team Members** | `*(Update before PR)*` 占位 | ✅ **必填**：真实姓名与单位 |
| **manifest.json** | 仍为旧 SuperPC 标题 / blend_cg / `submission_candidate` 路径 | ✅ **需重生**：跑 `bash src/post_submission_candidate.sh`（PD-LTS 全量后）或手动 `make_submission.py` |
| **README.md → Runtime** | 写「见 runtime.log」 | △ 全量 2155 跑完后补实测耗时（**非硬性**，但建议填） |
| **config/gate_decision.json** | 已同步 density | ✅ 一般无需改 |
| **SETUP.md** | PD-LTS 环境说明 | ✅ 组织方按需执行；检查 `download_pdlts.sh` 可访问 |
| **SUBMISSION_COMPLIANCE.md** | 已更新为 `verify_pdlts_ckpt` | ✅ |

**冒烟已通过**：`scripts/verify_submission_enhancement_only.sh` → 2 帧 val 可产出 ENH PLY。

**正式提交方式**：向 UVG 官方仓库提 **GitHub PR**（源码目录 `submissions/GC2026_Team_EnhancementOnly/`）；本地 tar 备份见 `output/meeting_delivery/submission/`（不入库）。

### 6.3 与提交包无关但汇报会用到的文档

| 文件 | 用途 |
|------|------|
| `MODEL_MODIFICATION_REPORT.md` | 论文 Method：改了什么 / 没改什么 |
| `SUPERPC_VAL565_RECORD.md` | SuperPC Phase2 实验细节 |
| `VAL565_METRICS_XLSX.md` | Excel 列含义 |
| `SUBMISSION_COMPLIANCE.md` | 官方目录合规核查 |
| 本文件 `PROJECT_STRATEGY_REPORT.md` | **总思路与答辩提示** |

---

## 附录：关键路径速查

```text
提交源码     submissions/GC2026_Team_EnhancementOnly/
构建提交包   scripts/build_pdlts_density_submission.sh
PD-LTS gate  output/enh_refine_p0_p1_p2/gate_decision.json
SuperPC gate output/val_grid/gate_decision.json（历史）
val565 Excel docs/meeting_delivery/val565_gc_baseline_metrics.xlsx
```

---

*供学长撰写答辩稿、论文 Introduction / Method / Ablation 时直接引用结构与数字。*
