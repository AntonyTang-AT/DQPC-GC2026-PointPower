# GC2026 Enhancement Only — 学长交付（精简版）

> **评估集**：官方 val565（TrumanShow + VictoryHeart + VirtualLife，564 帧）  
> **指标**：`chamfer_distance = (accuracy + completeness) / 2`（mm，对齐 HE）  
> **提交候选**：`holefill_adaptive_frame_gate_v2`（已 fine-tune PD-LTS 最佳融合）

## 五条主线结果

| # | 类别 | Preset | CD (mm) | 逐帧数据 |
|---|------|--------|---------|----------|
| 1 | **仅 SuperPC**（含后处理） | `filter_cg` + snap 1 mm | **18.353** | [01_superpc_best_val565.csv](metrics/01_superpc_best_val565.csv)（分序列汇总） |
| 2 | **仅 PD-LTS 未 fine-tune**（含后处理） | `vh_snap0` | **17.440** | [02_pdlts_frozen_best_val565.csv](metrics/02_pdlts_frozen_best_val565.csv) |
| 3 | **仅 PD-LTS 已 fine-tune**（含后处理） | `snap1 + fill0.6 density` | **14.883** | [03_pdlts_finetune_best_val565.csv](metrics/03_pdlts_finetune_best_val565.csv) |
| 4 | **未 fine-tune PD-LTS 最佳融合** | `region_hybrid` + density | **16.502** | [04_fusion_frozen_pdlts_best_val565.csv](metrics/04_fusion_frozen_pdlts_best_val565.csv) |
| 5 | **已 fine-tune PD-LTS 最佳融合（提交）** | `frame_gate v2` | **14.870** | [05_fusion_finetune_pdlts_best_val565.csv](metrics/05_fusion_finetune_pdlts_best_val565.csv) |
| — | CG baseline | 官方 CGv2 | 17.552 | Excel sheet2 |

- **汇总**： [metrics/models_registry.json](metrics/models_registry.json) · [metrics/summary.json](metrics/summary.json)
- **Excel**：[val565_five_models.xlsx](val565_five_models.xlsx)
- **完整报告**：[REPORT.md](REPORT.md)
- **提交 gate**：[config/submission_gate.json](config/submission_gate.json)

## 配图

| 文件 | 说明 |
|------|------|
| [figures/bar_val565_five_models.png](figures/bar_val565_five_models.png) | 五主线 + CG 分序列柱状图 |
| [figures/diagram_pipeline_pdlts_density.png](figures/diagram_pipeline_pdlts_density.png) | 管线示意 |
| [figures/compare_ts0072.png](figures/compare_ts0072.png) | TrumanShow 稀疏帧对比 |
| [figures/compare_vh0041.png](figures/compare_vh0041.png) | VictoryHeart 典型帧对比 |

## 提交包

```bash
# 构建
bash scripts/build_frame_gate_v2_submission.sh
# 打包产物
output/GC2026_submission_EnhancementOnly_frame_gate_v2.tar.gz
```

源码：`submissions/GC2026_Team_EnhancementOnly/`（Enhancement Only）

## 重新生成

```bash
export GC2026_ROOT=/path/to/GC2026
bash scripts/prepare_meeting_delivery.sh
```

本地镜像：`output/meeting_delivery/`
