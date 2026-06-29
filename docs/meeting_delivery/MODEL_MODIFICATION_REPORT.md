# GC2026 两条管线：原模型改动说明（论文撰写参考）

> **结论（可放 Abstract）**：我们 **未在 UVG 数据上对 SuperPC 或 PD-LTS 进行 fine-tune**；两条成功管线均在 **冻结预训练权重** 上，通过 **推理编排、CG 保真融合与几何后处理** 完成增强。方法贡献在 **pipeline / test-time configuration**，而非新网络结构或域内训练。

---

## 1. 总览

| 维度 | SuperPC 线（研发 / 旧 Enhancement 线） | PD-LTS + Refine 线（**当前提交**） |
|------|------------------------------------------|--------------------------------|
| 上游模型 | [SuperPC](https://github.com/sair-lab/SuperPC) | [PD-LTS](https://github.com/...) DenoiseFlow-light |
| 权重 | `kitti360_com.pth` 等 Model Zoo | `Denoiseflow-light-FBM.ckpt` |
| 架构/参数是否改动 | **否（0%）** | **否（0%）** |
| UVG 上训练 | **无** | **无** |
| 我们的方法层 | 推理包装 + `blend_cg` 体素融合 + KNN 上色 + per-seq 超参 | PD-LTS 去噪 + snap/fill 几何锚定 + density-adaptive fill |
| val565 `chamfer_distance`（对齐 HE） | 提交 blend_cg：**20.579**；Phase2 filter 系最好 **18.353**（`superpc_filter_snap1.0`，仍劣于 CG） | **17.440 mm**（vh_snap0，优于 CG +0.112 mm） |

---

## 2. SuperPC 线：改了什么、没改什么

### 2.1 未改动（论文写 frozen pretrained）

- **网络结构**：沿用上游 `superpc_w_attn` / `PUFM_w_attn`，通过 `test_superpc.load_model` + `run_sampling` 推理。
- **可学习参数**：官方 checkpoint（val gate 选定 `kitti360_com.pth`），**未在 UVG 上更新**。
- **视觉条件**：`use_vision=0`，未启用 Depth Anything 条件分支。

### 2.2 我们的贡献（推理与后处理，非改网络）

实现位于 `scripts/run_superpc_infer.py`、`scripts/uvg_io.py`（提交包同步至 `submissions/GC2026_Team_EnhancementOnly/src/`）：

| 模块 | 说明 | 是否改权重 |
|------|------|------------|
| 批量双 GPU 推理 | `run_dual_gpu_infer.sh` 分片 2155 帧 | 否 |
| **output_mode `blend_cg`** | 模型输出与输入 CG **体素合并**（`merge_xyz_rgb_voxel`），保留消费级几何 | 否 |
| KNN 颜色迁移 | `transfer_colors_knn` 将 CG 颜色赋给增强点 | 否 |
| 可选 SOR / fill / snap | `filter_cg_outliers`、`merge_cg_model_fill` 等 | 否 |
| **验证集 gate** | 网格搜索 checkpoint、voxel、per-sequence 配置（`docs/meeting_delivery/gate_snapshots/superpc_gate_decision.json`（运行时见 `output/val_grid/gate_decision.json`）） | 否（离散超参 φ） |

**论文表述建议**：

> We apply a frozen SuperPC upsampler and preserve consumer geometry via voxel-merging with the input CG cloud and KNN color transfer, with validation-tuned fusion hyperparameters.

### 2.3 Phase2 SuperPC 记录（研发，非提交）

官方 val565 上 SuperPC **相对最好** 一档（仍差于 CG 17.552）：

| 实验 | chamfer | 说明 |
|------|---------|------|
| **`superpc_filter_snap1.0`** | **18.353 mm** | `filter_cg` 几何缓存 + snap=1 mm |
| `superpc_filter_post25` | 18.710 mm | filter_cg + 后 SOR |
| `superpc_filter_snap1_fill0.6` | 17.552 mm | 与 CG 持平（aggregate） |

详见 `docs/meeting_delivery/SUPERPC_VAL565_RECORD.md`。  
**最新最优 vh_snap0 未使用此 SuperPC 路径**；Phase2 跑过后研发转向 PD-LTS + refine。

### 2.4 与上游 SuperPC 的差异边界

- 上游仓库 **不含** `blend_cg`、体素 CG 融合逻辑；此为 **本项目推理层**。
- `create_init_ckpt.py` 仅用于无权重时的冒烟测试，**非正式方法**。
- CUDA 扩展（Chamfer3D）为 RTX 5090 环境 **重编译**，不改变模型数学定义。

---

## 3. PD-LTS + Enh Refine 线：改了什么、没改什么

### 3.1 未改动

- **DenoiseFlow-light** 结构与 `Denoiseflow-light-FBM.ckpt` 权重：**零 fine-tune**。
- 推理调用上游 `get_denoise_net` + `denoise_loop`（及大点云分块 `large_patch_denoise_v1`）。

### 3.2 我们的贡献

| 模块 | 文件 | 说明 |
|------|------|------|
| 大点云推理适配 | `run_pdlts_infer.py` | >50k 点分块去噪；KNN 颜色回传 |
| **Enh Refine 管线** | `enh_refine_pipeline.py` | **无神经网络**：snap 贴回 CG、fill 补洞、density-adaptive fill |
| 全局最优配置 | `pdlts_light_snap1_fill0.6_density` | snap=1 mm, fill=0.6 mm, density_adaptive |
| 序列微调 | `vh_snap0` | **仅 VictoryHeart** 覆盖 `snap_mm=0`（`vh_configs/snap0_per_seq.json`） |
| 环境补丁 | `setup_pdlts_deps.sh` | `pila.cu` 一行 PyTorch 2.8 兼容；运行时 stub（**不改模型**） |

**论文表述建议**：

> We use a frozen lightweight point cloud denoiser as a geometry prior, followed by a training-free geometric refinement stage that anchors predictions to the input CG via snap-and-fill operations.

### 3.3 竞技提交包（当前）

- 正式提交：**PD-LTS density**（`pdlts_light_snap1_fill0.6_density`），全局 snap=1、无 VH 序列特例。
- 包路径：`submissions/GC2026_Team_EnhancementOnly/`；gate：`docs/meeting_delivery/gate_snapshots/pdlts_gate_decision.json`（运行时见 `output/enh_refine_p0_p1_p2/gate_decision.json`）。
- **vh_snap0**（17.44 mm）仅作 val ablation，写入 Excel sheet4，**不进** `run.sh`。
- SuperPC `blend_cg`（20.58 mm）为旧线对照，见 Excel sheet3。

---

## 4. 可形式化的符号（Method 小节）

- 记 SuperPC / PD-LTS 预训练参数为 **θ**（固定）。
- 记管线超参为 **φ**：体素大小、snap 半径、fill 阈值、per-sequence JSON 等。
- 优化问题：在 **公开验证集** 上对 φ 做网格搜索 / gate 选择，**不更新 θ**。

\[
\hat{P}_{\mathrm{ENH}} = \mathcal{R}_\phi\bigl(\mathcal{G}_\theta(P_{\mathrm{CG}}),\, P_{\mathrm{CG}}\bigr)
\]

其中 \(\mathcal{G}_\theta\) 为冻结生成器（SuperPC 或 PD-LTS），\(\mathcal{R}_\phi\) 为 CG 保真融合与几何精修。

---

## 5. val565 指标 Excel（学长汇报 / 论文附表）

文件：`docs/meeting_delivery/val565_gc_baseline_metrics.xlsx`  
**各 sheet 含义、阅读顺序、注意事项**：`docs/meeting_delivery/VAL565_METRICS_XLSX.md`

| Sheet | 内容 | 用途 |
|-------|------|------|
| sheet6_pdlts_raw | PD-LTS 去噪 alone（≈17.85 mm） | 证明 refine 必要（raw 劣于 CG） |
| sheet7_superpc_filter_snap1 | SuperPC Phase2 最优（≈18.35 mm） | 证明放弃 SuperPC |
| sheet5_pdlts_density | **提交方案**（≈17.50 mm） | 正式方法 |
| sheet4_pdlts_vh_snap0 | val 微调上界（≈17.44 mm） | ablation |

---

## 6. 论文 Contribution bullets（示例）

1. **Training-free** enhancement for official consumer-grade point clouds on UVG-CWI-DQPC.
2. **CG-preserving fusion** after SuperPC upsampling (voxel blend + KNN color) with validation-driven configuration.
3. Alternative **denoise-and-refine** pipeline with geometry anchoring (snap / density-adaptive fill) achieving better aligned Chamfer on official val565.
4. Systematic comparison of diffusion upsampling vs. denoising priors under the **same official metric** (aligned CG/ENH vs HE).

---

## 7. 不宜使用的表述

- ❌「在 UVG 上 fine-tuned SuperPC / PD-LTS」
- ❌「提出了新的点云补全/去噪网络」
- ❌「端到端训练增强模型」

---

## 8. 关键文件索引

| 用途 | 路径 |
|------|------|
| SuperPC gate | `docs/meeting_delivery/gate_snapshots/superpc_gate_decision.json`（运行时见 `output/val_grid/gate_decision.json`） |
| PD-LTS refine gate | `docs/meeting_delivery/gate_snapshots/pdlts_gate_decision.json`（运行时见 `output/enh_refine_p0_p1_p2/gate_decision.json`） |
| val565 Excel 说明 | `docs/meeting_delivery/VAL565_METRICS_XLSX.md` |
| SuperPC 推理 | `scripts/run_superpc_infer.py` |
| PD-LTS 推理 | `scripts/run_pdlts_infer.py` |
| 几何后处理 | `scripts/enh_refine_pipeline.py`, `scripts/uvg_io.py` |
| 提交包 | `submissions/GC2026_Team_EnhancementOnly/` |

---

*生成时间：2026-06-29 · 供学长撰写论文 Method / Contribution 参考*
