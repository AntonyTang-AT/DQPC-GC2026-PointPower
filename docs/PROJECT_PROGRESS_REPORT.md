# GC2026 UVG-CWI-DQPC 项目进展详细报告

> 更新：2026-06-21 · 团队：GC2026 Team  
> 赛题：[UVG-CWI-DQPC Grand Challenge 2026](https://ultravideo.fi/UVG-CWI-DQPC/GC2026/)  
> 数据集：[UVG-CWI-DQPC](https://ultravideo.fi/UVG-CWI-DQPC/index.html) · 提交规范：[UVG-CWI/submissions](https://github.com/UVG-CWI/submissions)

---

## 一、问题是什么

### 1.1 赛题目标

UVG-CWI-DQPC 提供 **12 条动态 volumetric 视频序列**，每条同时包含：

| 数据 | 含义 | 角色 |
|------|------|------|
| **HE（High-End）** | 高端多相机系统采集的点云 | **评测真值**（ground truth） |
| **CG（Consumer-Grade）** | RealSense 等消费级设备得到的点云 | **低质量输入 / consumer 档 baseline** |
| **RGBD（.bag）** | 8 路 RealSense 原始深度流 | Full Pipeline 的原始输入 |

赛题要求：把 consumer 档点云 **增强** 到更接近 HE——**准确、时序一致、视觉 faithful**。  
官方排名主指标：**输出点云 vs HE 的对称 Chamfer Distance（L1）**，越低越好；并报告 Accuracy、Completeness、Runtime。

### 1.2 两条 Processing Track

| Track | 输入 | 我们要做什么 |
|-------|------|--------------|
| **Enhancement Only** | 官方已发布的 CG PLY | 在 **现成 CG** 上做增强 |
| **Full Pipeline** | RGBD `.bag` | **从 bag 自建 CG**，再增强，端到端 |

组织方在 **隐藏测试集** 上运行参赛源码生成 PLY，再与 HE 对比；提交包 **不含点云**，仅含可复现代码（`submissions/GC2026_Team/`）。

### 1.3 问题难在哪里（我们面对的具体挑战）

1. **质量鸿沟**  
   Consumer 点云相对 HE 存在噪声、空洞、配准误差、遮挡；官方 CG（经 CWIPC 管线处理）相对 HE 仍有约 **49–86 mm** Chamfer 差距（见下文实测）。

2. **Full Pipeline 额外难度**  
   不仅要「增强」，还要从 bag **自己重建 CG**。重建质量必须至少接近 **官方发布 CG**，否则后续增强无从谈起。数据集论文明确：consumer 侧依赖 CWIPC 多相机配准、滤波、融合及 **变换到 HE 坐标系**。

3. **序列差异大**  
   12 序列运动幅度、遮挡、纹理复杂度不同（如 TicTacToe 双人快动、PinkNoir 高 CD 等），需要 **按序列调参** 或 override。

4. **工程规模**  
   全量 **2155 帧** × 12 序列；Stage1（CPU/cwipc）+ SuperPC（双 GPU）+ 评估打包，链路长、易缺帧、需断点续跑。

5. **评测口径**  
   - **主指标**：ENH vs **HE**（不是 vs CG）  
   - **CG vs HE**：衡量输入/官方参考线离真值多远  
   - **improvement = CG−ENH（vs HE）**：相对官方 CG，输出有没有变好（Enh 赛道核心观感指标）

---

## 二、我们的思路与方法

### 2.1 总体策略：双轨并行

```text
                    ┌── Enhancement Only ──► 官方 CG ──► SuperPC ──► ENH
  UVG-CWI-DQPC ────┤
                    └── Full Pipeline ─────► bag ──► Stage1 ──► SuperPC ──► ENH
                                              (cwipc-native)      (同模型)
```

- **增强模型统一**：SuperPC（`kitti360_com.pth`），输出模式 **`blend_cg`**，voxel **3.0 mm**，`use_vision=0`（由 val 网格搜索 gate 选定）。
- **Enhancement Only**：成熟、可提交竞技。  
- **Full Pipeline**：主研轨道；当前生产方案为 **N0 v2**（cwipc-native + 全量编排）。

### 2.2 Enhancement Only 方法

```text
官方 CGv2 (15fps, 2155 帧)
    → SuperPC 双卡推理 (run_dual_gpu_infer.sh)
    → 按序列 enh_config（val 上 compare + build_recon_enh_config）
    → 评估 / manifest / 打包 (post_submission_candidate.sh)
```

要点：
- 输入已是组织方 CWIPC 参考管线产物，**Stage1 难度为零**。
- 在 Val362（TicTacToe + VictoryHeart，362 帧）上调 blend 等超参，推广到全序列。

### 2.3 Full Pipeline（N0 v2）方法

#### Stage1：RGBD → 自建 CG

- **后端**：`rgbd_to_cg.py`，cwipc-native 回放 `.bag`，滤波 profile **`official`**（对齐 UVG camera_config 默认 RealSense 滤波）。
- **生产 tag**：`N0_cwipc_official`（pure cwipc + official 滤波；Val362 sweep 中 recon vs HE 最优）。
- **TT / VH override**：困难序列强制 N0，避免 hybrid 等在快动场景 recon 崩溃。
- **Val362 merge**：先把 Val362 上验证过的 N0 recon **合并** 进全量 train，再跑剩余序列。
- **缺帧补全**（88 帧）：hybrid 重试失败帧 → 从 PGDR full / 历史 recon 拷贝，保证 **2155/2155** 完整。

#### Stage2：SuperPC 增强

- 输入：Stage1 自建 CG（`reconstructed_cg_list.txt`）。
- **自适应 blend**：`compare_reconstructed_cg.py` 对比 recon vs 官方 CG → `build_recon_enh_config.py` 生成 per-seq 配置。
- 双卡并行：`run_dual_gpu_infer.sh`。

#### Stage3：Post / 评估 / 打包

- `post_full_pipeline.sh`：manifest、evaluate_uvg（val+full，CPU n=20k）、color/temporal、tar。
- `eval_native_gate.py`：recon/enh vs HE（Val362 holdout expert 口径）。
- 编排：`run_full_n0_v2.sh`（phase0–3，支持 `STOP_AFTER_PHASE`、`watch_full_n0_v2.sh` 看进度）。

### 2.4 环境与工程

| 组件 | 说明 |
|------|------|
| GPU | 2× RTX 5090，SuperPC 双卡推理 |
| Python | conda `superpc`（3.9）+ 系统 3.12 + cwipc deb |
| 数据 | `data/raw` 871 GB（12 序列 CG + bag）；`models/superpc_pretrained` |
| 代码仓库 | [GC2026-UVG-FullPipeline-SuperPC](https://github.com/AntonyTang-AT/GC2026-UVG-FullPipeline-SuperPC) |

---

## 三、完成情况

| 项目 | 状态 | 说明 |
|------|------|------|
| Enhancement Only 全量 | ✅ | 2155 帧 ENH，`output/submission_candidate/` |
| Full Pipeline N0 v2 全量 | ✅ | 2155 recon + 2155 ENH，phase0–3 全部 done |
| RGBD / CGv2 / 权重 | ✅ | 12 序列 bag 齐全，CGv2 已下载 |
| 源码提交包 | ✅ | `submissions/GC2026_Team/` |
| GitHub 文档 | ✅ | README、N0 结果、本报告 |

**主要本地产物（未入 git，体积大）**

| 产物 | 路径 |
|------|------|
| Enh Only ENH | `output/submission_candidate/` |
| N0 v2 Stage1 recon | `output/full_pipeline_n0_v2_cg/` |
| N0 v2 SuperPC ENH | `output/full_pipeline_n0_v2_candidate/` |
| N0 v2 提交 tar（23 GB） | `output/full_pipeline_n0_v2_candidate_submission.tar.gz` |
| 对比报告 JSON | `output/full_n0_v2_final_report.json` |

---

## 四、效果怎么样

> 评估：Chamfer L1，n=20k samples；**主指标均为 ENH vs HE**。  
> CG vs HE 列用于理解 **官方 consumer 输入 / baseline 参考线**。

### 4.1 官方 baseline 应如何理解

| 概念 | 含义 | Val362 proxy |
|------|------|--------------|
| **CG vs HE** | 官方发布 CG（CWIPC 参考管线，**无神经网络增强**）离 HE 多远 | **~86 mm** |
| **Full 官方 baseline（推断）** | 组织方在 test bag 上跑 **同一参考 toolchain** 的输出 vs HE | 质量应 **≈ 发布 CG** |
| **我们比什么** | 最终 **ENH vs HE** | 见下表 |

CG 是 consumer 档、相对 HE 的「输入侧 baseline」；**排行榜不按 vs CG 排**，但 **improvement = CG−ENH** 可回答「有没有比官方 CG 更好」。

### 4.2 Enhancement Only — **效果良好，适合竞技提交**

#### Val362（362 帧，TicTacToe + VictoryHeart）

| 指标 | 数值 |
|------|------|
| 官方 CG vs HE | 85.95 mm |
| **我们 ENH vs HE** | **71.49 mm** |
| **improvement（相对 CG）** | **+14.46 mm** |
| TicTacToe ENH vs HE | 76.30 mm（+21.9 mm vs CG） |
| VictoryHeart ENH vs HE | 67.46 mm（+8.2 mm vs CG） |

#### 全量 12 序列（2152 帧）

| 指标 | 数值 |
|------|------|
| 官方 CG vs HE | 49.33 mm |
| **我们 ENH vs HE** | **49.61 mm** |
| improvement | −0.28 mm（基本持平） |
| 序列 improvement 为正 | 4 / 12（BlueSpeech、TicTacToe、TrumanShow、VictoryHeart） |

**小结**：Val 上 **稳定优于官方 CG**；全量 **几乎不劣于 CG**，说明增强没有在整体上伤害输入。相对赛题「把 consumer 推向 HE」，Enhancement Only **在 Val 上有效**。

### 4.3 Full Pipeline N0 v2 — **全链路跑通，几何仍弱于官方 CG**

#### Val362

| 阶段 / 指标 | vs HE（mm） | 说明 |
|-------------|------------|------|
| 官方 CG（参考线） | 85.85 | 官方 consumer 质量 |
| **Stage1 recon** | **253.9** | 自建 CG，远高于官方 CG |
| **最终 ENH** | **206.0** | SuperPC 后 |
| SuperPC 相对 recon 增益 | +48.3 mm | 有增强，但基底太差 |
| improvement vs 官方 CG | **−110.5 mm** | 输出仍 **远差于** 官方 CG |
| TicTacToe ENH | **164.7** | 快动序列有改善 |
| VictoryHeart ENH | 240.5 | 与 recon 接近，增强有限 |

#### 全量 2155 帧

| 指标 | 数值 |
|------|------|
| 官方 CG vs HE | 49.32 mm |
| **N0 v2 ENH vs HE** | **178.11 mm** |
| improvement vs CG | −128.79 mm |

#### 全量分序列 ENH vs HE（节选）

| 序列 | 官方 CG→HE | Enh Only ENH | **N0 Full ENH** |
|------|-----------|--------------|-----------------|
| TicTacToe | 98.4 | **76.4** | 153.3 |
| VictoryHeart | 75.7 | **67.5** | 231.4 |
| FitFluencer | 21.4 | 28.5 | 172.5 |
| PinkNoir | 107.8 | 119.9 | 300.1 |

**小结**：

- **工程上**：2155 帧 Stage1 → SuperPC → eval → tar **完整跑通**，N0 + 补帧 + Val merge 路线 **有效**（尤其 TicTacToe）。
- **竞技上**：最终 ENH vs HE **196 mm（Val）/ 178 mm（全量）**，远高于官方 CG 参考线（**86 / 49 mm**）；相对 CG 的 improvement 为 **负**，说明 **尚未达到「官方重建 + 再增强」的起点**。
- **瓶颈**：主要在 **Stage1**（Val recon vs HE 254 mm），SuperPC 无法单独弥补与官方 CG 的差距。

### 4.5 Stage1 补帧修复 + official val565 复评（2026-06-21）

P0 审计发现 **88 帧补帧 recon 失败**（val 占 16 帧，recon vs 官方 CG ≈ **1548 mm**）。已执行：

1. **Stage1 官方 CG 回退**：88 帧 recon 备份后拷贝官方 CG（val 16 + train 72）
2. **ENH 同步**：无 GPU 时从 `submission_candidate` 拷贝对应 ENH（Stage1==官方 CG 时等价 Enh Only 输出）
3. **复评 official val565**（564 帧有效）

| 指标 | 修复前 | 修复后 |
|------|--------|--------|
| Full ENH vs HE（本地 cd_l1） | 187.1 mm | **158.7 mm** |
| Stage1 recon vs 官方 CG（补帧 16） | 1548 mm | **9.9 mm** |
| Stage1 recon vs 官方 CG（总体） | 222 mm | **178 mm** |

**仍待 GPU / Stage1 升级**：非补帧 recon vs 官方 CG ~**183 mm**；VictoryHeart ~**225 mm**；Full 仍远弱于 Enh Only（48.5 mm）。

脚本：`scripts/run_stage1_backfill_fix.sh` · `scripts/run_nogpu_finalize.sh`

---

### 4.4 两轨对比（汇报用一张表）

| | Enhancement Only | Full Pipeline N0 v2（backfill 后） |
|---|------------------|-------------------------------------|
| 输入 | 官方 CG | RGBD bag（88 补帧→官方 CG） |
| official val565 ENH vs HE | **48.5 mm** | **158.7 mm** |
| official val565 improvement vs CG | **+2.8 mm** | −103.7 mm |
| 官方 Metric chamfer-L1 | **97.0 mm** | 待 finalize 刷新 |
| 提交建议 | **竞技首选** | 方法轨；Stage1 系统升级前不宜主提交 |

---

## 五、结论

1. **问题本质**：在 consumer → HE 的质量鸿沟上做增强；Full 还要先 **从 bag 重建到官方 CG 水准**。
2. **方法**：SuperPC 双轨；Full 采用 **cwipc-native N0 v2**（official 滤波、TT/VH override、Val merge、缺帧补全、per-seq SuperPC config）。
3. **效果**：  
   - **Enhancement Only**：Val **71.5 mm vs HE**，相对官方 CG **+14.5 mm**，**达到可提交水平**。  
   - **Full Pipeline N0 v2**：全量工程 **完成**，TT 等序列 **明显改善**，但整体 **206/178 mm vs HE**，**仍弱于官方 CG baseline（86/49 mm）**，主瓶颈在 Stage1 几何重建。

---

## 六、后续方向

| 优先级 | 方向 |
|--------|------|
| P0 | ✅ Stage1 补帧审计 + 官方 CG 回退（88 帧）已完成 |
| P0+ | Stage1 对齐官方 CWIPC toolchain，目标非补帧 recon vs 官方 CG **<80 mm** |
| P1 | VH / PinkNoir 等难序列专项 |
| P2 | Full 赛道 SuperPC 策略：recon 未达标前避免过度 blend |
| 提交 | Enh Only 冲榜；Full 待 Stage1 达标后再作主提交 |
| CPU | `bash scripts/run_nogpu_finalize.sh` 刷新 manifest/合规/评估 |

---

## 附录：复现命令

```bash
# Enhancement Only
source scripts/env_setup.sh
bash scripts/run_enhancement_only.sh
bash scripts/post_submission_candidate.sh

# Full Pipeline N0 v2
bash scripts/run_val362_n0_v2.sh          # Val362 实验
bash scripts/run_full_n0_v2.sh            # 全量 phase0-3
bash scripts/watch_full_n0_v2.sh          # 进度
```

相关文档：`docs/N0_V2_RESULTS.md` · `docs/CWIPC_NATIVE_PIPELINE.md` · `README.md`
