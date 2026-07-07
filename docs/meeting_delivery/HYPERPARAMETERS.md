# GC2026 Enhancement Only — 超参数完整说明

> 本文档自包含：所有数值直接列出，并解释每个参数的含义。  
> **评估集**：val565（564 帧，TrumanShow / VictoryHeart / VirtualLife）  
> **训练集**：1590 帧（9 序列，不含 val565）

---

## 0. 公共几何后处理参数（Enh Refine）

以下参数在多条模型线中共用，名称与代码 preset 字段一致。

| 参数 | 典型值 | 含义 |
|------|--------|------|
| **snap_mm** | 0 ~ 1.5 mm | **Snap（吸附）**：把增强点云中离 CG 参考点过远的点，沿最短方向拉到 CG 表面附近。越小越保守（保 accuracy），越大越贴模型几何。CG 点本身永不删除。 |
| **fill_mm** | 0 ~ 0.6 mm | **Fill（填洞）基础半径**：在 CG 稀疏/有空洞的区域，从模型点云补点。0 表示不填洞。 |
| **fill_mode** | `density_adaptive` | 填洞模式。`density_adaptive` = 根据 CG 局部密度自适应放大 fill 半径（越稀疏补得越多）；`fixed` = 固定半径。 |
| **fill_density_k** | 6 | 估计 CG 局部密度时，每个点看最近 **6** 个 CG 邻居。 |
| **fill_density_scale_max** | 1.3 ~ 2.0 | 密度自适应 fill 的最大放大倍数（相对 fill_mm）。例如 fill_mm=0.6、scale_max=2.0 时，最稀疏处等效约 1.2 mm。 |
| **pre_sor** | true/false | **Pre-SOR**：在几何处理**之前**对 CG 做统计离群点去除。 |
| **post_sor** | true/false | **Post-SOR**：在 snap/fill **之后**对合并点云做统计离群点去除（去飞点）。 |
| **pre_sor_nb / post_sor_nb** | 20 | SOR 算法：每个点看 **20** 个邻居。 |
| **pre_sor_std / post_sor_std** | 2.5 | SOR 阈值：邻居平均距离超过全局均值 + **2.5×标准差** 的点视为离群并删除。 |
| **fill_before_snap** | true/false | **阶段顺序开关**：`true` = 先 fill 再 snap；`false` = **先 snap 再 fill**（默认）。 |
| **blend_voxel_mm** | 0 ~ 3.0 mm | 体素合并分辨率；0 表示不做体素 merge。 |
| **geometry_fallback** | `filter_cg` | 当外部几何缓存缺失时，回退为对 CG 做 SOR（不跑神经网络）。 |

**SOR（Statistical Outlier Removal）**：基于邻域距离统计的**几何去噪**，不是神经网络；通常放在管线末尾作「清飞点」。

---

## 1. 仅 SuperPC（sheet3，val565 CD = **18.353 mm**）

### 1.1 神经网络推理（SuperPC 扩散上采样，无 UVG 训练）

| 参数 | 数值 | 含义 |
|------|------|------|
| 权重文件 | `kitti360_com.pth`（约 144 MB） | KITTI-360 上预训练的 SuperPC 完整度模型 |
| 网络结构 | `superpc_w_attn` | 带 attention 的 SuperPC 变体 |
| **num-points** | **2048** | 从输入 CG 随机/重采样 **2048** 点送入网络 |
| **target-num-points** | **8192** | 网络输出目标点数 **8192**（上采样） |
| **sampling-steps** | **25** | 扩散采样迭代 **25** 步 |
| **seed** | **21** | 随机种子，保证可复现 |
| **use_vision** | **0（关闭）** | 不使用 RGB 图像条件，仅几何 |
| **output_mode** | **`filter_cg`** | 输出模式：先跑 SuperPC 模型，再对结果做 SOR，并与 CG 合并策略配合（本线 gc_baseline 最优） |
| filter_cg SOR | nb=**20**, std=**2.0** | SuperPC 输出点云的轻量去飞点 |
| **color-knn** | **1** | 输出颜色：每个 ENH 点在 CG 上找 **1** 近邻复制 RGB |
| **device** | cuda | GPU 推理 |

> 说明：早期 val 网格在 **evaluate_uvg cd_l1** 口径下 `blend_cg + voxel 3.0 mm` 最优；在 **gc_baseline chamfer_distance** 口径下，sheet3 报告的是 **filter_cg + snap 1 mm**（Phase2 记录 18.353 mm）。

### 1.2 后处理（preset：`superpc_filter_snap1.0`）

| 参数 | 数值 | 含义 |
|------|------|------|
| 几何来源 | SuperPC `filter_cg` 模式输出 PLY | 上节神经网络 + filter_cg 的结果 |
| **snap_mm** | **1.0** | 将 SuperPC 几何吸附到 CG，容差 1 mm |
| **fill_mm** | **0** | 本线不填洞 |
| **pre_sor / post_sor** | **false** | 不再额外 SOR |
| **stage_order** | 仅 snap | 无 fill 阶段 |

**完整链路**：`CG → SuperPC(kitti360, 2048→8192, 25 steps) → filter_cg SOR → snap 1 mm → KNN 上色 → ENH`

---

## 2. 仅 PD-LTS 冻结（sheet4，val565 CD = **17.440 mm**，preset `vh_snap0`）

### 2.1 PD-LTS 去噪推理（官方权重，无 fine-tune）

| 参数 | 数值 | 含义 |
|------|------|------|
| 权重文件 | `Denoiseflow-light-FBM.ckpt` | PD-LTS 官方 light 模型（FBM 预训练） |
| 模型规模 | **light** | 轻量 DenoiseFlow（另有 heavy 未在本线使用） |
| **cluster_size** | **50000** | 大点云分块：每块最多 **50000** 点送入去噪 |
| **large_threshold** | **50000** | 点数超过 **50000** 才启用分块；否则整帧一次去噪 |
| 小帧 patch_size | **1000** | 小点云 patch 大小 |
| seed_k | **3** | 去噪迭代种子邻居数 |
| niters | **1** | 去噪迭代 **1** 轮 |
| **color-knn** | **1** | 颜色从 CG 迁移 |
| **device** | cuda | GPU |

### 2.2 后处理（`vh_snap0`）

基线 preset 为 `pdlts_light_snap1_fill0.6_density`，VictoryHeart 序列单独覆盖 snap。

| 参数 | TrumanShow / VirtualLife | VictoryHeart | 含义 |
|------|--------------------------|--------------|------|
| **snap_mm** | **1.0** | **0.0** | VH 上 snap 反而 hurt，故 snap=0 |
| **fill_mm** | **0.6** | **0.6** | 填洞基础半径 0.6 mm |
| **fill_mode** | density_adaptive | 同左 | 密度自适应填洞 |
| **fill_density_k** | **6** | **6** | 密度估计邻居数 |
| **fill_density_scale_max** | **2.0** | **2.0** | 最大 fill 放大 2× |
| **post_sor** | **false** | **false** | 不做末尾 SOR |
| **fill_before_snap** | **false** | **false** | **先 snap，再 fill** |

**完整链路**：`CG → PD-LTS light 去噪 → snap → density fill → KNN 上色 → ENH`

---

## 3. 仅 PD-LTS UVG fine-tune（sheet5 对照，CD = **14.883 mm**）

### 3.1 训练超参数（实际跑完的一次：2026-06-30，4×RTX 5090）

| 参数 | 数值 | 含义 |
|------|------|------|
| **max_epochs** | **20** | 最多训练 **20** 个 epoch（实际保存 epoch 19 的 ckpt） |
| **batch_size** | **4** | 每个 GPU 每步 **4** 个 patch |
| **GPU 数量** | **4** | DDP 四卡并行 → 有效 batch ≈ **16** patch/step |
| **patches_per_epoch** | **8000** | 每个 epoch 随机采样 **8000** 个 CG/HE patch 对 |
| **learning_rate** | **5×10⁻⁴** | Adam 学习率 **0.0005** |
| **max_points** | **30000** | 每帧 CG/HE 最多读 **30000** 点 |
| **patch_size** | **1024** | 每个训练 patch **1024** 点 |
| **num_workers** | **8** | DataLoader **8** 进程 |
| **precision** | **32** | FP32 训练 |
| **seed** | **42** | 随机种子 |
| 训练帧数 | **1590** | 官方 train split，**不含 val565** |
| 预训练初始化 | Denoiseflow-light-FBM.ckpt | 从官方 light 权重微调 |
| early stopping | **未启用** | 跑满 20 epoch |
| 产出权重 | `DenoiseFlow-light-UVG-finetune.ckpt` | 路径：`output/pdlts_finetune_uvg/run_20260630_230223/` |

**Smoke 训练**（调试）：16 帧、batch=2、patches=64、1 epoch、1 GPU。

### 3.2 推理 + Refine

与 sheet4 相同算子：`snap 1.0 + fill 0.6 density`，仅权重换为 UVG fine-tune ckpt。

---

## 4. 提交线：ft PD-LTS + frame_gate v2（sheet7，CD = **14.870 mm**）

### 4.1 两路神经网络

| 角色 | 权重 / 来源 | 含义 |
|------|-------------|------|
| **Primary** | UVG fine-tune PD-LTS light | 主表面几何，每帧必用 |
| **Secondary** | SuperPC kitti360，`blend_cg` 全量缓存 | 仅在 gate 允许时用于填 CG 洞区 |
| PD-LTS cluster_size | **50000** | 同 sheet4 |

**Secondary SuperPC 全量推理参数**（生成 submission_candidate）：

| 参数 | 数值 |
|------|------|
| checkpoint | kitti360_com.pth |
| output_mode | **blend_cg** |
| blend_voxel_mm | **3.0 mm** |
| use_vision | **0** |
| num-points / target / steps | 2048 / 8192 / 25 |

### 4.2 Primary density refine（每帧必做，architecture v2）

| 参数 | 数值 | 顺序 |
|------|------|------|
| snap_mm | **1.0** | **① 先执行** |
| fill_mm | **0.6** | **② 后执行** |
| fill_mode | density_adaptive | |
| fill_density_k | **6** | |
| fill_density_scale_max | **2.0** | |

→ Primary 支路固定为 **snap → fill**（不是 fill 在前）。

### 4.3 Frame fill gate（是否加 SuperPC）

| 参数 | 数值 | 含义 |
|------|------|------|
| frame_fill_gate | **true** | 逐帧决定是否引入 SuperPC |
| skip 序列 | VictoryHeart, VirtualLife | 这两序列 **永不** 加 SuperPC |
| probe_fill_mm | **0.25** | 探测阶段 fill 半径 |
| skip_add_ratio | **0.022** | 预计新增点占比 &lt; **2.2%** → tier **skip** |
| full_add_ratio | **0.040** | 预计新增点占比 ≥ **4.0%** → tier **full** |
| 中间档 | lite | 介于两者之间 |

**各 tier 的 SuperPC fill**：

| Tier | fill_mm | max_fill_ratio | post_sor |
|------|---------|----------------|----------|
| skip | 0 | — | 否 |
| lite | **0.25** | **10%** | 否（adaptive_post_sor 可跳） |
| full | **0.6** | **15%** | 是（std=2.5） |

### 4.4 SuperPC 填洞支路（fill_before_snap = true）

当 gate 非 skip 时：

| 参数 | 数值 | 含义 |
|------|------|------|
| **fill_before_snap** | **true** | **先** 把 SuperPC 点填入 CG 洞区，**再** snap |
| hybrid_fill_role | secondary_only | 表面仍是 PD-LTS primary，SuperPC 只作填洞源 |
| hybrid_hole_mask | cg_holes | 只在 CG 空洞区域补点 |
| hybrid_voxel_mm | **0.5** | hybrid 内部体素参考 |

### 4.5 Post-SOR

| 参数 | 数值 | 含义 |
|------|------|------|
| post_sor_nb | **20** | 邻居数 |
| post_sor_std | **2.5** | 离群阈值 |
| adaptive_post_sor | **true** | 若 SuperPC 新增点 &lt; 总点数 **2%**，跳过 SOR |

**提交完整顺序**：

```text
CG
 → PD-LTS ft 去噪
 → [primary] snap 1.0 → fill 0.6 density
 → frame_fill_gate
 → [optional] SuperPC fill → snap（fill_before_snap）
 → [optional] post SOR
 → KNN 颜色
 → ENH
```

---

## 5. 「Line B」与 fill / snap 顺序（易混点）

项目里 **Line B** 有两种说法，顺序不同：

| 名称 | 指什么 | fill / snap 顺序 |
|------|--------|------------------|
| **报告中的「线 B」** | 仅 PD-LTS（sheet4） | **先 snap，再 fill**（fill_before_snap=false） |
| **Fusion 实验 Line B** | preset `holefill_first_...` | SuperPC 支路：**先 fill，再 snap，再 post SOR**（fill_before_snap=true） |
| **当前提交 frame_gate v2** | sheet7 | Primary：**snap→fill**；SuperPC 支路：**fill→snap** |

因此：**Fusion Line B 的「先填再 snap」仅作用于 SuperPC 支路**；frame_gate v2 保留该顺序但加门控，且 Primary 仍为 snap→fill。全量 CD 对比与各 preset 换模过程见 **[FUSION_EVOLUTION.md](FUSION_EVOLUTION.md)**。

---

## 6. 可视化用 SuperPC 几何（sheet3 配图）

| 项目 | 说明 |
|------|------|
| 指标 CD | 来自 Phase2 **filter_cg + snap1** 全量评估（18.353 mm 均值） |
| 配图几何 | `output/meeting_delivery_viz/superpc_filter_cg_geom/`（filter_cg 推理）+ snap1 |
| 旧版 fallback | 曾误用 `submission_candidate`（blend_cg 3.0 mm），**与 sheet3 指标不一致**；已废弃 |
| 逐帧 CD 标注 | 对配图帧现场 gc_baseline 评估（因 sheet3 CSV 仅分序列汇总） |

---

## 7. 快速对照

| 模型线 | 训练 | Epoch | Batch/GPU | LR | 主 refine 顺序 |
|--------|------|-------|-----------|-----|----------------|
| SuperPC only | 否 | — | — | — | snap only |
| PD-LTS frozen | 否 | — | — | — | snap → fill |
| PD-LTS finetune | 是 | 20 | 4×4 | 5e-4 | snap → fill |
| Fusion submit | ft + 门控 SuperPC | 20（仅 PD-LTS） | 4×4 | 5e-4 | primary snap→fill；SuperPC fill→snap |

---

## 8. 评估指标参数

| 参数 | 数值 | 含义 |
|------|------|------|
| chamfer_distance | (accuracy + completeness) / 2 | 官方 gc_baseline 主指标，单位 mm |
| 对齐 | 每序列固定 4×4 transform | CG/ENH 对齐到 HE 坐标系 |
| F-score 阈值 | 10 / 20 / 30 / 50 mm | 辅助报告阈值 |

---

## 9. 论文「实验设置」段落写法（学长参考样式）

学长给的参考图属于 **Implementation Details / Experimental Setup**：用一段话交代 **硬件 → 优化器 → 超参 → 训练轮数 → 模型选择准则**。本项目可按同样结构写（数值以实际为准，勿照抄参考图的 200 epoch / 1e-4）：

> **Hardware.** UVG fine-tune 在 **4× NVIDIA RTX 5090（32 GB）** 上以 DDP 训练；SuperPC / PD-LTS 推理与 val565 评估亦在 CUDA GPU 上完成。  
> **Optimization.** PD-LTS light 使用 **Adam**，learning rate **5×10⁻⁴**，batch size **4 per GPU**（有效 batch **16** patch/step），每 epoch **8000** 个 CG/HE patch（patch size **1024** 点）。  
> **Training.** Fine-tune **20 epochs**，从官方 `Denoiseflow-light-FBM.ckpt` 初始化；**未**做 grid search（Enhancement 线后处理 snap/fill/gate 在 val565 上网格或 ablation 选定）。  
> **Model selection.** 使用 **epoch 19** checkpoint（`DenoiseFlow-light-UVG-finetune.ckpt`）作提交 primary；门控 SuperPC 参数来自 val565 preset 搜索（见 `config/submission_gate.json`）。  
> **Inference-only lines.** SuperPC（kitti360）与冻结 PD-LTS **无 UVG 训练**；sheet3/4 仅报告推理 + 几何后处理超参（§1–2）。

与参考图的对应关系：

| 参考图要素 | 本项目 |
|------------|--------|
| GPU 型号与数量 | 4× RTX 5090（训练）；推理可单卡/多卡 shard |
| Optimizer / LR / Batch | Adam / 5e-4 / 4×4=16 effective |
| Epochs | **20**（非 200；SuperPC 无训练） |
| Grid search | 后处理与 fusion **preset** 在 val565 上搜；PD-LTS **网络结构未搜** |
| 模型选择 | 固定 epoch 19 ckpt + gate JSON（非按 val MSE 早停） |

答辩或论文中 **三模型配图** 的超参见 §1–4 表格；**训练段** 仅 sheet5/7 的 PD-LTS ft 需要 §3.1 + 上段文字。
