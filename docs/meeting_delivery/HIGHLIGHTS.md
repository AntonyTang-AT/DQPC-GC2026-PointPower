# GC2026 Enhancement Only — 技术 Highlight（答辩 / 论文用）

> **提交线**：`holefill_adaptive_frame_gate_v2`  
> **核心数字**：val565 **CD 14.870 mm**（564 帧）｜CG **17.552 mm**｜**+2.68 mm**  
> **代码入口**：`submissions/GC2026_Team/` → `run_enhancement_only.sh`

---

## Highlight 1：Domain-Adapted Denoising with CG-Anchored Geometric Refinement

**Problem.** Immersive point-cloud enhancement under the UVG Grand Challenge must lift consumer-grade (CG) captures toward high-end (HE) fidelity without replacing the acquisition pipeline. A strong upsampling baseline—SuperPC with `filter_cg` and 1 mm snapping—still underperforms the official CG input (18.35 vs. 17.55 mm Chamfer CD under `gc_baseline`). Frozen PD-LTS denoising yields only marginal gains (17.44 mm), indicating that generic pre-training is insufficient for in-the-wild human point clouds.

**Approach.** We adopt a two-stage enhancement strategy: (i) **domain-adapted neural denoising** via fine-tuning DenoiseFlow-light on 1,590 UVG training frames (9 sequences, excluding the validation split), and (ii) **CG-preserving geometric refinement** that explicitly trades accuracy for completeness while retaining all input CG points.

**Method.** Fine-tuning uses Adam (lr = 1×10⁻⁴, batch size 4) for 19 epochs, producing `DenoiseFlow-light-UVG-finetune.ckpt`. At inference, large frames are processed in chunks of 50k points with a single denoising iteration. The denoised geometry is aligned to the organizer's per-sequence transform. Refinement applies **snap-then-fill**: snap (1.0 mm) pulls enhanced points toward the CG manifold to preserve accuracy; density-adaptive fill (base 0.6 mm, k = 6 neighbors, scale up to 2×) supplements sparse CG regions. Colors are transferred from CG via 1-NN lookup, ensuring no HE leakage.

**Results.** On val565 (564 frames), fine-tuned PD-LTS with snap-and-fill achieves **14.883 mm** CD, improving over CG by **2.67 mm** and over frozen PD-LTS by **2.46 mm**. This configuration accounts for **>99%** of the final submission gain; subsequent fusion contributes only 0.013 mm.

---

## Highlight 2：Frame-Adaptive Gating for Secondary Hole Filling

**Problem.** Naïvely coupling fine-tuned denoising with SuperPC-based hole filling degrades overall quality. A hole-fill-first variant (Line B: fill → snap, post-SOR) reaches 15.159 mm on val565—**0.276 mm worse** than denoising-only—and **every** VictoryHeart frame regresses, revealing that completion operators are sequence- and frame-dependent rather than universally beneficial.

**Approach.** We formulate secondary SuperPC insertion as a **conditional refinement step** governed by a lightweight, interpretable **frame-fill gate**. The gate estimates the expected benefit of hole filling (`est_add_ratio`) before merging upsampled points, thereby avoiding harmful completion on dense body regions while retaining gains on sparse TrumanShow frames.

**Method.** The submitted pipeline (`holefill_adaptive_frame_gate_v2`) enforces a fixed stage order: PD-LTS denoising → primary density refine (always applied) → gate decision → optional SuperPC merge → adaptive post-SOR → CG color transfer. Sequence-level hard skips disable the SuperPC branch entirely on VictoryHeart and VirtualLife. Per-frame tiers are assigned by `est_add_ratio`: **skip** (< 0.022), **lite** (0.022–0.040; fill 0.25 mm, ≤10% new points), and **full** (≥ 0.040; fill 0.6 mm, ≤15%). SuperPC geometry (`kitti360`, blend_cg, 3.0 mm voxel) is merged only within CG hole masks using fill-before-snap. Architecture v2 ensures that skipped frames still receive the full primary refine path.

**Results.** Frame-gate v2 achieves **14.870 mm** on val565, outperforming denoising-only (14.883 mm) and hole-fill-first (15.159 mm). Gains are localized to TrumanShow (−0.044 mm); VictoryHeart and VirtualLife remain identical to the fine-tuned baseline (0.000 mm), confirming that the gate successfully suppresses detrimental filling.

---

## Highlight 3：CG-preserving 一体化增强 — 非「去噪→补全→上采样」三模块简单串联

### 与文献三子任务的映射

| 文献子任务 | 本项目实现 | 关键约束 |
|------------|------------|----------|
| **Denoising** | PD-LTS UVG-FT（最前）+ 可选 Post-SOR（最后） | 网络去噪 **必须在 snap/fill 之前** |
| **Completion** | density fill 0.6 + 门控 SuperPC 洞区 merge | **以 CG 为 mask/锚点**；VH/VL 整序列 skip |
| **Upsampling** | SuperPC 仅 secondary，非主路径 | 单跑 SuperPC **劣于 CG**，故不作提交主策略 |

### 硬约束（提交包 `enh_refine_pipeline.py`）

1. **CG 点不删除** — snap 只位移、fill 只增补；评测侧 CG 集合保留。
2. **Primary 固定 snap → fill** — 与 sheet5 ft-only 一致，避免 Line B 式 primary fill-first。
3. **SuperPC 支路 fill → snap** — 仅 gate 通过帧；merge 限制在 **CG 洞区**。
4. **颜色永远来自 CG** — 组织方 immersion 场景下避免 HE 泄漏。
5. **评测口径 gc_baseline** — CG/ENH 乘对齐矩阵，HE 不乘；Chamfer n=20k + accuracy/completeness。

### 公式（框架图）

\[
\hat{P}_{\mathrm{ENH}} = \mathcal{R}_\phi\!\left(\mathcal{G}^{\mathrm{FT}}_\theta(P_{\mathrm{CG}}),\, P_{\mathrm{CG}},\, \mathcal{G}^{\mathrm{SP}}(P_{\mathrm{CG}})\right)
\]

- \(\mathcal{G}^{\mathrm{FT}}\)：UVG fine-tune PD-LTS  
- \(\mathcal{R}_\phi\)：snap + density fill + gated hybrid + Post-SOR + KNN  
- \(\mathcal{G}^{\mathrm{SP}}\)：门控 SuperPC hole-fill（可选）

---

## Highlight 4：Systematic Evaluation on Real-World Immersive Point Clouds

**Problem.** Prior point-cloud enhancement literature often evaluates denoising, completion, and upsampling in isolation on synthetic or object-centric datasets, leaving a gap in **systematic, perceptually motivated benchmarking** for real-world immersive media where CG-to-HE enhancement must respect acquisition constraints.

**Approach.** We conduct a **controlled ablation study** on the official UVG-CWI-DQPC benchmark under the organizer-aligned `gc_baseline` protocol, comparing five representative pipelines that span upsampling-only, frozen and fine-tuned denoising, region-based hybrid fusion, and our gated submission.

**Experimental setup.** Evaluation covers 564 validation frames from three immersive human sequences (TrumanShow, VictoryHeart, VirtualLife). Metrics include Chamfer distance (20k subsampled points), accuracy, and completeness, with CG/ENH aligned via official transforms and HE left unaligned per competition rules. All methods share consistent post-processing families and are reported with per-frame CSVs for reproducibility.

**Findings.** (1) Upsampling alone (SuperPC + filter_cg + snap) **fails** to beat CG (18.35 mm). (2) Frozen PD-LTS plateaus at 17.44 mm. (3) Fine-tuned denoising with CG-anchored refine yields the dominant improvement (14.88 mm). (4) Ungated hybrid strategies (region hybrid: 16.50 mm; hole-fill-first: 15.16 mm) confirm that blind completion hurts dense sequences. (5) Our gated submission (14.87 mm) achieves the best overall CD while preserving per-sequence stability. Together, these results provide an evidence chain linking module roles to measurable accuracy–completeness trade-offs in a **real-world immersive enhancement** setting.

---

## 答辩一句话（中文）

我们在 **UVG 官方 CG→HE 人体点云** 上，用 **UVG 微调 PD-LTS 去噪 + CG 锚定 snap/fill** 拿到 **14.883 mm**，再通过 **帧级 SuperPC 门控**（VH/VL 整序列 skip）微调到 **14.870 mm**，以 **CG-preserving 推理编排** 替代无脑三模块串联，全链路 **gc_baseline 可复现**。

## 答辩一句话（English）

We improve official UVG CG→HE enhancement from **17.55 mm to 14.87 mm** Chamfer CD on **564 val frames** via **UVG-finetuned PD-LTS denoising**, **CG-anchored snap and density-adaptive filling**, and **frame-level gated SuperPC hole filling**, with hard **CG preservation** and organizer-aligned **gc_baseline** evaluation.

---

## 相关文档

| 文档 | 内容 |
|------|------|
| [REPORT.md](REPORT.md) | 完整技术报告 §4 提交路线 |
| [HYPERPARAMETERS.md](HYPERPARAMETERS.md) | 训练/推理参数表 |
| [FUSION_EVOLUTION.md](FUSION_EVOLUTION.md) | Line B → gate v2 换模记录 |
| [figures/diagram_model_framework.png](figures/diagram_model_framework.png) | 提交管线框架图 |
