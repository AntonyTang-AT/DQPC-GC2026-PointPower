# SuperPC 在官方 val565 上的实验记录

> 口径：`evaluate_gc_baseline_metrics.py` — 对齐矩阵 + 全点 + `chamfer_distance = (accuracy + completeness) / 2`  
> CG baseline：**17.552 mm**（`ACMMM26_GC_baseline.csv` / val565）

---

## 1. 重点记录：`superpc_filter_snap1.0`

| 字段 | 值 |
|------|-----|
| **实验名** | `superpc_filter_snap1.0` |
| **含义** | SuperPC **`filter_cg` 模式** 几何缓存（`kitti360_com_filter_cg_v0_vx0`）+ Enh Refine **snap=1 mm** |
| **val565 均值 chamfer** | **18.353 mm**（`18.3528080857124`） |
| **相对 CG** | **−0.80 mm**（劣于 baseline） |
| **与 `filter_cg` 关系** | 数值与纯 CG+SOR 的 `filter_cg` **完全相同** → 在该设定下 snap 未改变 aggregate |
| **跑批时间** | 2026-06-27（`output/enh_refine_phase2/phase2b.log` / `phase2_resume.log`） |
| **持久化结果** | 汇总见 `output/enh_refine_phase2/summary_val565.json`、`_summary_lines.jsonl`、`gate_decision.json` |
| **PLY / 逐帧 CSV** | **已不在磁盘**（`enh_refine_phase2/superpc_filter_snap1.0/` 目录已清理）；几何源缓存 `output/val_grid_official565/kitti360_com_filter_cg_v0_vx0` 亦已不存在 |

### 配置定义（代码）

```191:193:scripts/enh_refine_config.py
    _from_src("superpc_filter_snap1.0", "superpc_filter_cg", snap_mm=1.0),
    _from_src("superpc_filter_snap1_fill0.6", "superpc_filter_cg", snap_mm=1.0, fill_mm=0.6),
    _from_src("superpc_filter_post25", "superpc_filter_cg", post_sor=True, post_sor_std=2.5),
```

几何源注册名 `superpc_filter_cg` → 曾为 `output/val_grid_official565/kitti360_com_filter_cg_v0_vx0`（565 帧）。

### Phase2 同批 SuperPC 相关结果

| 实验 | chamfer (mm) | vs CG |
|------|-------------|-------|
| `superpc_filter_snap1_fill0.6` | 17.552 | 持平（等同 CG） |
| **`superpc_filter_snap1.0`** | **18.353** | −0.80 |
| `superpc_filter_post25` | 18.710 | −1.16 |
| `filter_cg`（无 SuperPC，仅 SOR） | 18.353 | −0.80 |

---

## 2. 提交线 SuperPC（`blend_cg`，非 Phase2）

| 配置 | chamfer (mm) | 说明 |
|------|-------------|------|
| **submission_candidate** | **20.579** | kitti360 + `blend_cg` + voxel 3.0 mm；2155 帧全量；竞技提交包 |
| Phase2 `filter_cg` 系 | 18.35 | 不同 `output_mode`，val 网格 `filter_cg` 缓存 |

**结论**：在官方对齐 val565 上，**SuperPC 最好一档是 ~18.35 mm（filter_cg 系）**，仍 **不如 CG 17.55**；提交用的 **blend_cg 更差（20.58 mm）**。

---

## 3. 含 SuperPC 的混合实验（最新选型轮次）

| 实验 | chamfer (mm) | 目录 |
|------|-------------|------|
| hybrid_pdlts_superpc + superfill | 18.198 | `output/enh_refine_val565_selection/hybrid_pdlts_superpc_snap1_fill0.6_superfill/` |
| hybrid_pdlts_superpc + density | 17.953 | `.../hybrid_pdlts_superpc_snap1_fill0.6_density/` |

混合使用 **PD-LTS 几何 + submission SuperPC** 做 fill，不是 `superpc_filter_snap1.0`。

---

## 4. Phase2 与「最新模型」的关系（是否跑过 Phase2？）

**跑过。** 时间线如下：

```
2026-06-27  Phase2 (enh_refine_phase2)
            ├─ 2A: cg_passthrough, filter_cg
            ├─ 2B: superpc_filter_snap1.0 / snap1_fill0.6 / post25  ← SuperPC filter 系
            └─ 2C: pdlts_light_snap1.0 / snap1_fill0.6 / adapt      ← 胜出方向

2026-06-27+ Phase2D snap/fill 网格 → P0/P1/P2 → density_adaptive

2026-06-29  val565_selection (enh_refine_val565_selection)
            ├─ 在 density 基线上做 temporal / hybrid / fp_migrated / vh_snap0
            └─ **未再跑** superpc_filter_* preset
            最终最优：vh_snap0 = 17.440 mm（纯 PD-LTS refine，无 SuperPC）
```

| 问题 | 答案 |
|------|------|
| 最新最优 **vh_snap0** 有没有跑 Phase2？ | **有间接关系**：PD-LTS + snap/fill 来自 Phase2C；但 **vh_snap0 本身在 val565_selection 轮次生成**，不是 Phase2 目录下的 preset |
| 最新选型有没有再评 **superpc_filter_snap1.0**？ | **没有** — `run_val565_selection.sh` 只跑 hybrid / temporal / fp_migrated / VH 微调 |
| Phase2 的 SuperPC 产物还在吗？ | **汇总 JSON + 日志在**；**PLY 与逐帧 eval CSV 已删**；仅 `pdlts_light_snap1_fill0.6` 仍保留 565 帧 |

**给学长一句话**：最新模型走的是 **Phase2 之后 PD-LTS 线**（density → vh_snap0），**没有**把 `superpc_filter_snap1.0` 并进最终提交；SuperPC 在 val565 上 **历史最好 ~18.35 mm** 有记录，但 **劣于 CG**，故研发转向 PD-LTS。

---

## 5. 复现 `superpc_filter_snap1.0`（若需逐帧 CSV）

1. 重跑 val565 网格生成 `kitti360_com_filter_cg_v0_vx0`（或从备份恢复）
2. `bash scripts/run_enh_refine_phase2.sh` 且 `PHASE=2b`
3. 评估：`evaluate_gc_baseline_metrics.py --test-root output/enh_refine_phase2/superpc_filter_snap1.0`

---

*生成：2026-06-29 · 路径：`docs/meeting_delivery/SUPERPC_VAL565_RECORD.md`*
