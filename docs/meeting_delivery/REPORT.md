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

## 4. 最优提交路线详解（回答「先填充再去噪？」）

**结论（一句话）**：不是「先填洞再去噪网络」；而是 **先用 PD-LTS 神经网络去噪**，再做 **几何 snap/fill**，最后在少数帧 **可选 SuperPC 填洞 + 统计离群点去除（SOR）**。

### 4.1 整体阶段顺序（`holefill_adaptive_frame_gate_v2`）

```text
官方 CG PLY
  │
  ├─[A] PD-LTS light（UVG fine-tune 权重）── 神经网络去噪，得到 primary 几何
  │
  ├─[B] Primary density refine（每帧必做，architecture v2）
  │      ① snap 1.0 mm（把点拉向 CG，保 accuracy）
  │      ② fill 0.6 mm density-adaptive（在 CG 稀疏区补点，保 completeness）
  │
  ├─[C] Frame fill gate（逐帧探测 est_add_ratio）
  │      skip │ lite │ full ── 决定是否引入 SuperPC secondary
  │      VH / VL 序列：强制 skip（不加 SuperPC）
  │
  ├─[D] 可选 SuperPC 填洞（仅 TrumanShow 等通过 gate 的帧）
  │      secondary = submission_candidate（kitti360 blend_cg vx=3.0）
  │      仅在 CG 洞区 merge；fill_before_snap=true → 先填 SuperPC 点再 snap
  │      lite: fill 0.25 mm / max 10%；full: fill 0.6 mm / max 15%
  │
  ├─[E] Post SOR 统计去噪（nb=20, std=2.5）
  │      adaptive：新增点占比 < 2% 则跳过（避免过度平滑）
  │
  └─[F] KNN 颜色从输入 CG 迁移 → 写 ENH PLY
```

### 4.2 与学长的「填充 / 去噪」对应关系

| 说法 | 本项目的实际含义 |
|------|------------------|
| **去噪** | ① **PD-LTS 网络**（主去噪，管线最前）；② **Post SOR**（几何后统计滤波，管线末尾可选） |
| **填充** | **Density-adaptive fill**（primary 0.6 mm）+ 可选 **SuperPC hole fill**（secondary） |
| **先填再去噪？** | **神经网络去噪始终在最前**。几何阶段因 preset 而异（见下表） |
| **为何不用 SuperPC 单线** | gc_baseline 下 SuperPC+filter+snap（18.35 mm）仍劣于 CG（17.55 mm）；SuperPC 仅作 **门控填洞** |

**几何阶段 fill / snap 顺序（可并存，不矛盾）**：

| 管线 | fill_before_snap | 实际顺序 |
|------|------------------|----------|
| **线 B：仅 PD-LTS**（sheet4 `vh_snap0`） | false | **snap → fill** |
| **Fusion 实验 Line B**（`holefill_first_...`） | true | SuperPC 支路：**fill → snap → post SOR** |
| **提交 primary refine**（frame_gate v2） | —（独立函数） | **snap → fill**（固定） |
| **提交 SuperPC 支路**（frame_gate v2） | true | **fill → snap** |

> 若学长记忆中的「Line B 填充在前」指的是 **Fusion holefill-first 实验**，那是对的；若指 **仅 PD-LTS 的线 B**，则是 **snap 在前、fill 在后**。详见 [HYPERPARAMETERS.md §5](HYPERPARAMETERS.md#5-line-b-与-fill--snap-顺序易混点)。

### 4.3 配图三模型详解（sheet3 / sheet4 / sheet7）

配图脚本 `scripts/render_three_models_comparison.py` 固定展示 **CG + 下列三模型 + HE** 五列；每列上/下（或左/右）为全景与局部 ROI。局部 ROI 由 **CG 相对 HE 高误差区** 自动选取（故意展示问题区域）；HE 列红框通过 **CG→HE 最近邻对应** 单独圈定，详见 [HE_ROI_ANALYSIS.md](HE_ROI_ANALYSIS.md)。

---

#### 4.3.1 模型 A — SuperPC only（sheet3，val565 CD = **18.353 mm**）

**定位**：纯几何上采样基线，证明在 gc_baseline 口径下 **单跑 SuperPC 打不过 CG**。

**设计动机**：SuperPC 是扩散式点云上采样，擅长补全稀疏区，但会引入与 CG 不一致的几何；本线只用 **几何 filter + snap 锚定**，不加 PD-LTS，作为「无 UVG 域适配神经网络」的对照。

**逐步流程**：

```text
官方 CG PLY
  │
  ├─[1] SuperPC 推理（冻结 kitti360_com.pth）
  │      use_vision=0（纯几何，不用 RGB）
  │      2048 输入点 → 8192 输出点，25 扩散步
  │
  ├─[2] filter_cg 后处理
  │      对 SuperPC 输出做 SOR（nb=20, std=2.0）去飞点
  │      与 CG 合并：保留 CG 点 + 过滤后的 SuperPC 新增点（非 blend 体素）
  │
  ├─[3] snap 1.0 mm
  │      把 ENH 点拉向 CG 最近邻，限制在 1 mm 内，保 accuracy
  │      本线 **不做 density fill**（Phase2 表明加 fill 不能救回 CD）
  │
  └─[4] KNN 颜色从输入 CG 迁移 → ENH PLY
```

**与 CG 的差异**：SuperPC 会 **增点** 填洞，但 snap 后整体仍偏离 HE（accuracy 侧劣化）；val565 全局 CD **18.353 > CG 17.552**。

**配图数据来源**：`output/meeting_delivery_viz/superpc_filter_cg_geom/`（6 帧 filter_cg 推理缓存）+ snap1。

---

#### 4.3.2 模型 B — PD-LTS 冻结 + 后处理（sheet4 `vh_snap0`，CD = **17.440 mm**）

**定位**：**不 fine-tune** 的 PD-LTS 最优 ablation；说明「仅换后处理超参」也能略优于 CG，但远不如 UVG ft。

**设计动机**：PD-LTS 原文在潜空间去噪；我们在 **欧氏空间** 用 CG 硬锚定（snap/fill），避免去噪后点云漂移。VictoryHeart 序列上 snap 过强会伤 completeness，故 val 最优为 **VH 序列 snap=0**（`vh_snap0`）。

**逐步流程**：

```text
官方 CG PLY
  │
  ├─[1] PD-LTS light 去噪（冻结 Denoiseflow-light-FBM.ckpt）
  │      Flow Matching 去噪网络，输入 CG 点坐标 → primary 去噪几何
  │      无 UVG 域适配，权重为通用 FBM 预训练
  │
  ├─[2] snap（序列相关）
  │      TrumanShow / VirtualLife：snap 1.0 mm（拉向 CG）
  │      VictoryHeart：**snap 0 mm**（仅保留去噪结果，不额外拉点）
  │
  ├─[3] density-adaptive fill 0.6 mm
  │      在 CG 相对 primary 稀疏的区域补点（体素密度对比）
  │      提升 completeness，CG 原点永不删除
  │
  └─[4] KNN 颜色从 CG 迁移 → ENH PLY
```

**与 SuperPC 线对比**：无 SuperPC 增点；靠 **神经网络去噪 + 几何 refine**。raw PD-LTS  alone 17.854 mm（劣于 CG），**snap/fill 是必要第二步**。

**为何叫 vh_snap0**：全局统一 snap=1 的配置 17.504 mm；VH 上 snap=0 略优 → sheet4 报告 **17.440 mm**（564 帧 val565）。

---

#### 4.3.3 模型 C — 提交线 frame_gate v2（sheet7，CD = **14.870 mm**）

**定位**：当前 **Enhancement Only 提交** preset；ft PD-LTS + 门控 SuperPC 填洞。

**设计动机**：
1. UVG fine-tune 把 PD-LTS 拉到 **14.883 mm**（无 SuperPC 基线）
2. Line B 实验证明 SuperPC「先 fill 再 snap」在 **TrumanShow 大洞帧** 有效，但 **VictoryHeart 全序列变差**（15.159 mm > 14.883 mm）
3. v2 用 **逐帧 gate + VH/VL 序列 skip**，只在「值得填」的帧启用 SuperPC，且 primary 恒做 density refine

**逐步流程**（与 §4.1 一致，此处按配图语义展开）：

```text
官方 CG PLY
  │
  ├─[1] PD-LTS light（UVG fine-tune：DenoiseFlow-light-UVG-finetune.ckpt）
  │      神经网络去噪 → primary 几何（管线最前，不可与 fill 对调）
  │
  ├─[2] Primary density refine（每帧必做，architecture v2）
  │      ① snap 1.0 mm → ② fill 0.6 mm density-adaptive
  │      skip 帧也不再输出裸 primary（v1 缺陷已修）
  │
  ├─[3] Frame fill gate（逐帧 est_add_ratio）
  │      探测 CG 洞区相对 primary 的缺失比例
  │      tier：skip │ lite（fill 0.25, max 10%）│ full（fill 0.6, max 15%）
  │      VictoryHeart / VirtualLife：**整序列 force skip**（不加 SuperPC）
  │
  ├─[4] 可选 SuperPC secondary（仅 gate 通过帧，主要在 TrumanShow）
  │      secondary = kitti360 blend_cg（vx=3.0 mm）submission 几何
  │      仅在 CG 洞 mask 内 merge SuperPC 点
  │      fill_before_snap=true：**先填 SuperPC 点 → 再 snap**（继承 Line B 支路顺序）
  │
  ├─[5] Post SOR（nb=20, std=2.5，adaptive：新增点 <2% 则跳过）
  │
  └─[6] KNN 颜色从 CG 迁移 → ENH PLY
```

**相对模型 A/B 的关键差异**：

| 维度 | SuperPC only | PD-LTS frozen | frame_gate v2 |
|------|--------------|---------------|---------------|
| 主网络 | SuperPC kitti360 | 冻结 FBM | **UVG ft PD-LTS** |
| SuperPC | 全程使用 | 不用 | **门控、仅 TS 等** |
| Primary refine | 仅 snap | snap + fill | **恒 snap + fill** |
| val565 CD | 18.353 | 17.440 | **14.870** |

**分序列**：TS −0.044 mm vs ft；VH/VL 与纯 ft **完全一致**（0.000 mm Δ）。

完整 preset 字段见 `config/submission_gate.json`；各模型 epoch/batch 见 **[HYPERPARAMETERS.md](HYPERPARAMETERS.md)**；Line B → v2 换模过程见 **[FUSION_EVOLUTION.md](FUSION_EVOLUTION.md)**。

---

## 5. 方法要点（论文 Method）

### 5.1 相对 PD-LTS

\[
\hat{P}_{\mathrm{ENH}} = \mathcal{R}_\phi\bigl(\mathcal{G}_\theta(P_{\mathrm{CG}}),\, P_{\mathrm{CG}}\bigr)
\]

- \(\mathcal{G}_\theta\)：PD-LTS 去噪（提交线经 UVG fine-tune）
- \(\mathcal{R}_\phi\)：**snap**（accuracy）+ **density-adaptive fill**（completeness），CG 点永不删除
- 与 PD-LTS 原文差异：在 **欧氏空间** 用 CG 硬锚定，而非仅潜空间去噪

### 5.2 相对 SuperPC

\[
\hat{P} = \mathcal{F}_\phi\bigl(\mathcal{G}^{\mathrm{SP}}_\theta(P_{\mathrm{CG}}),\, P_{\mathrm{CG}}\bigr)
\]

- \(\mathcal{G}^{\mathrm{SP}}_\theta\)：冻结扩散上采样
- \(\mathcal{F}_\phi\)：体素 merge / filter / 区域或帧级填洞
- val565 结论：即使最优 filter+snap，仍打不过 CG

### 5.3 frame_gate v2（提交）

```text
CG → ft PD-LTS → [always] snap1 + fill0.6 density
              → frame_fill_gate(est_add_ratio)
              → [optional] SuperPC blend_cg hole fill
              → KNN color from CG
```

---

## 6. 提交合规

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

## 7. 数据文件说明

| 文件 | 内容 |
|------|------|
| `metrics/01_superpc_best_val565.csv` | SuperPC 最优；分序列 + 全局一行 |
| `metrics/02_pdlts_frozen_best_val565.csv` | vh_snap0；564 逐帧 |
| `metrics/03_pdlts_finetune_best_val565.csv` | ft density；564 逐帧 |
| `metrics/04_fusion_frozen_pdlts_best_val565.csv` | region_hybrid；564 逐帧 |
| `metrics/05_fusion_finetune_pdlts_best_val565.csv` | frame_gate v2；564 逐帧 |
| `val565_five_models.xlsx` | sheet1 汇总 + sheet2 CG + sheet3–7 各主线 |
| `config/submission_gate.json` | 提交 preset 完整 JSON |
| `figures/compare3_*_{cols,lr}_*.png` | CG + sheet3/4/7 三模型 + HE（上全下局部 **或** 左全右局部） |
| `figures/compare5_*.png` | （旧）五模型七列对比 |
| [HYPERPARAMETERS.md](HYPERPARAMETERS.md) | 各模型 epoch / batch / refine 数值 |

---

## 8. 汇报提示

- **两套指标不可混用**：早期 SuperPC gate 用 `evaluate_uvg` cd_l1（~75 mm）；本文全部 gc_baseline（~17 mm / ~15 mm ft 线）
- **vh_snap0** 为 val 最优 ablation（VH snap=0），正式提交采用 **全局统一** gate
- **SuperPC** 在融合中有用（TS 稀疏帧），但必须 **门控** 避免 VH/VL 劣化

---

*由 `scripts/prepare_meeting_delivery.sh` 自动生成数据与图表；报告正文可随仓库版本手动修订。*
