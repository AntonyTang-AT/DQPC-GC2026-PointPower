# PointPower 研发管线索引

> 把「最终提交包」与「研发实验脚本 / 证据」对应起来。  
> 最终可运行方案：`submissions/PointPower/`（官方 PR 合并版）= `submissions/GC2026_Team_EnhancementOnly/`（本地主包）。

---

## 1. 三阶段思路 → 代码位置

| 阶段 | 思路 | 提交包实现 |
|------|------|------------|
| **Stage 1** | 可逆 latent 去噪（PD-LTS light UVG finetune） | `src/run_dual_gpu_pdlts.sh`, `run_pdlts_infer.py` |
| **Stage 2** | 空间锚定 + primary 密度 refine（snap 1 mm + fill 0.6） | `src/enh_refine_pipeline.py`, preset in `config/gate_decision.json` |
| **Stage 3** | 帧级 gate + 条件 SuperPC blend_cg 补洞 | `src/frame_fill_gate.py`, `run_enh_refine_infer.py` |

Preset 名称：**`holefill_adaptive_frame_gate_v2`**

---

## 2. 五条主线 → 脚本与文档

| 主线 | val565 CD (mm) | 关键脚本 | 说明文档 |
|------|----------------|----------|----------|
| 仅 SuperPC + 后处理 | 18.353 | `scripts/run_val_grid_official565*.sh` | [`docs/meeting_delivery/REPORT.md`](meeting_delivery/REPORT.md) §3.1 |
| 仅 PD-LTS 冻结 + refine | 17.440 | `scripts/run_enh_refine_p0_p1_p2*.sh` | REPORT §3.2 |
| **仅 PD-LTS UVG finetune + refine** | **14.883** | `scripts/run_pdlts_finetune_uvg.*` | REPORT §3.3 |
| 冻结 PD-LTS + region hybrid | 16.502 | `scripts/run_ft_val565_fusion*.sh` | REPORT §3.4 |
| **ft PD-LTS + frame_gate v2（提交）** | **14.870** | `scripts/build_frame_gate_v2_submission.sh` | [`FUSION_EVOLUTION.md`](meeting_delivery/FUSION_EVOLUTION.md) |

---

## 3. Line B → frame_gate v2 决策链

```
Line B (holefill-first, 全序列 SuperPC)
  → val565 15.159 mm（劣于 ft 14.883）
  → 证据: docs/meeting_delivery/evidence/lineb_failure_analysis.json
  → 文档: docs/meeting_delivery/FUSION_EVOLUTION.md

frame_gate v2（TS 稀疏帧 fill；VH/VL 整序列 skip SuperPC）
  → val565 14.870 mm
  → 证据: docs/meeting_delivery/evidence/frame_gate_v2_val565_eval.json
  → preset: config/gate_decision.json + evidence/enh_refine_gate_decision.json
```

---

## 4. 构建与验证提交包

| 步骤 | 命令 |
|------|------|
| 构建 frame_gate v2 包 | `bash scripts/build_frame_gate_v2_submission.sh` |
| 冒烟验证 | `bash scripts/verify_submission_enhancement_only.sh` |
| 2 帧全流程 | `bash submissions/PointPower/src/run_smoke.sh` |
| 官方 Chamfer 评估 | `bash submissions/PointPower/src/post_submission_candidate.sh` |

---

## 5. 证据文件（P1，已入库）

| 文件 | 内容 |
|------|------|
| [`meeting_delivery/evidence/enh_refine_gate_decision.json`](meeting_delivery/evidence/gate_decision.json) | 最终 refine / gate preset |
| [`meeting_delivery/evidence/summary_val565.json`](meeting_delivery/evidence/summary_val565.json) | P0–P2 ablation 汇总 |
| [`meeting_delivery/evidence/param_review.json`](meeting_delivery/evidence/param_review.json) | 融合线参数回顾 |
| [`meeting_delivery/evidence/lineb_failure_analysis.json`](meeting_delivery/evidence/lineb_failure_analysis.json) | Line B 分序列失败分析 |
| [`meeting_delivery/evidence/frame_gate_v2_val565_eval.json`](meeting_delivery/evidence/frame_gate_v2_val565_eval.json) | 提交方案 14.870 mm 全帧评估 |

---

## 6. 数据划分与评估

| 用途 | 路径 |
|------|------|
| Train/val 自动划分 | `submissions/PointPower/data/generate_pair_lists.sh` |
| Metric 对齐 + Chamfer | `src/download_metric.sh` → `src/evaluate_uvg.py` |
| 上游依赖 | `src/download_pdlts.sh`, `src/download_pretrained.sh`（**kitti360** 超 100 MB，运行时下载） |

---

## 7. Full Pipeline（研发线，非竞技提交）

| 组件 | 脚本 |
|------|------|
| RGBD → CG Stage1 | `scripts/rgbd_to_cg.py`, `scripts/run_full_n0_v2.sh` |
| 提交包副本 | `submissions/GC2026_Team_FullPipeline/` |
| 结果文档 | [`docs/N0_V2_RESULTS.md`](N0_V2_RESULTS.md) |
