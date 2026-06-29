# val565_gc_baseline_metrics.xlsx 说明

> 文件路径：`docs/meeting_delivery/val565_gc_baseline_metrics.xlsx`  
> 用途：**学长汇报 / 论文附表**（非 UVG 官方提交物）  
> 评估集：官方 val565（TrumanShow + VictoryHeart + VirtualLife，**564 帧**）  
> 指标：`chamfer_distance = (accuracy + completeness) / 2`（mm），与 `ACMMM26_GC_baseline.csv` 同口径；对 test 点云施加官方 per-sequence 对齐矩阵后与 HE 比较。

---

## 推荐阅读顺序（讲故事）

```text
sheet2 CG baseline
  → sheet6 PD-LTS raw（去噪 alone，仍差于 CG）
  → sheet7 SuperPC filter+snap（SuperPC 最好一档，仍差于 CG）
  → sheet3 SuperPC blend_cg（旧提交线，更差）
  → sheet5 pdlts_density（当前提交方案）
  → sheet4 vh_snap0（val 上界 ablation，不进提交包）
```

**sheet1_summary** 一行看完所有模型均值与分序列均值。

---

## 各 Sheet 含义

| Sheet | 内容 | 粒度 | 用途 |
|-------|------|------|------|
| **sheet1_summary** | 各模型 val565 均值 + 三序列均值 | 汇总 | 答辩/论文 Table 1 素材 |
| **sheet1_meta** | 指标口径、生成时间 | 元数据 | 避免与 `evaluate_uvg`（~48–75 mm）混淆 |
| **sheet2_cg_baseline** | 官方 CG vs HE | **564 逐帧** | 下限参照；未增强消费级点云 |
| **sheet3_superpc_blend_cg** | SuperPC `kitti360` + `blend_cg` + voxel 3 mm | 564 逐帧 | 旧 Enhancement 提交线；说明为何放弃 SuperPC |
| **sheet4_pdlts_vh_snap0** | density + **仅 VictoryHeart snap=0** | 564 逐帧 | val 全局最优；**论文 ablation**，不进正式提交 |
| **sheet5_pdlts_density** | `pdlts_light_snap1_fill0.6_density` | 564 逐帧 | **当前 UVG 提交方案**（全局 snap=1，density fill） |
| **sheet6_pdlts_raw** | PD-LTS light 去噪，**无** snap/fill refine | 564 逐帧 | 量化 refine 阶段贡献（raw 17.85 → density 17.50 mm） |
| **sheet7_superpc_filter_snap1** | SuperPC `filter_cg` 几何 + snap 1 mm（Phase2） | **3 序列均值 + 1 行全局** | SuperPC 线历史最优（18.35 mm，仍劣于 CG）；逐帧 CSV 已删，见 `note` 列 |

---

## 关键数字（均值 chamfer, mm）

| model | 均值 | vs CG (17.552) | 角色 |
|-------|------|----------------|------|
| cg_baseline_official | 17.552 | — | 参照 |
| pdlts_density（提交） | **17.504** | **+0.048** | 正式方案 |
| vh_snap0 | 17.440 | +0.112 | ablation |
| pdlts_raw | 17.854 | −0.302 | refine 前 |
| superpc_filter_snap1.0 | 18.353 | −0.801 | SuperPC 最优 |
| superpc_blend_cg | 20.579 | −3.027 | 旧提交线 |

`improvement_cg_minus_enh > 0` 表示 ENH 优于 CG。

---

## sheet6 / sheet7 特别注意

### sheet6_pdlts_raw

- **管线**：官方 CG → PD-LTS `Denoiseflow-light-FBM.ckpt` → KNN 上色 → 直接评估。  
- **没有** snap、fill、density_adaptive。  
- **用途**：证明单独 PD-LTS 去噪 **不如 CG**；必须加 refine 才有提交级效果。

### sheet7_superpc_filter_snap1

- **管线**：SuperPC `filter_cg` 模式几何缓存 + snap 1 mm（Phase2，2026-06-27）。  
- **逐帧 PLY/CSV 已从磁盘清理**；本 sheet 为 **分序列均值 3 行 + 全局聚合 1 行**（`granularity` 列区分）。  
- 与 `filter_cg` 几何在 aggregate 上等价（`note_same_as_filter_cg`）。  
- **用途**：说明研发阶段曾探索 SuperPC，**最好仍劣于 CG**，故转向 PD-LTS。

---

## 源 CSV 路径

| Sheet | CSV |
|-------|-----|
| sheet2 | `ACMMM26_GC_baseline.csv`（筛 val 三序列） |
| sheet3 | `metrics/01_superpc_blend_cg_kitti360_vx3.0_val565.csv` |
| sheet4 | `metrics/02_pdlts_vh_snap0_val565.csv` |
| sheet5 | `metrics/03_pdlts_density_global_snap_no_vh_tune_val565.csv` |
| sheet6 | `metrics/04_pdlts_raw_val565.csv` |
| sheet7 | `metrics/05_superpc_filter_snap1.0_val565.csv` |

重新生成：

```bash
python scripts/export_gc_baseline_csv_from_json.py \
  --in-json output/pdlts_val565/light/evaluation_gc_baseline_val565.json \
  --out-csv docs/meeting_delivery/metrics/04_pdlts_raw_val565.csv
python scripts/export_superpc_filter_per_seq_csv.py
python scripts/merge_val565_metrics_xlsx.py
```

---

## 不是什么

- **不是**全量 2155 帧评估（仅官方 val 子集）。  
- **不是** `evaluate_uvg` 的 cd_l1（~75 mm 那套与本文 **不可横比**）。  
- **不是** UVG 组织方要求的提交文件（提交物为 `submissions/GC2026_Team_EnhancementOnly/` 源码 PR）。
