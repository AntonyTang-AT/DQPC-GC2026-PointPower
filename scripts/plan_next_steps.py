#!/usr/bin/env python3
"""Analyze gate results and write NEXT_STEPS.md with prioritized follow-ups."""
from __future__ import annotations

import json
import os
from datetime import datetime

GC2026_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GRID_ROOT = os.path.join(GC2026_ROOT, "output/val_grid_official565")
OUT = os.path.join(GRID_ROOT, "NEXT_STEPS.md")

CG_BASELINE = 17.551553246708043
# After fast grid: blend vx1.0=19.08; vx>1.0 monotonically worse — cap search at 1.0 mm
VOXEL_POLICY_MAX_MM = 1.0
RECOMMENDED_BLEND_VX = 1.0
RECOMMENDED_MODES = ("filter_cg", "filter_blend_cg", "fill_cg", "blend_cg")


def load(path: str) -> dict | None:
    if not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def main() -> None:
    gate = load(os.path.join(GRID_ROOT, "gate_decision.json")) or {}
    winner_vs = load(os.path.join(GRID_ROOT, "winner_vs_baseline.json"))
    summary = load(os.path.join(GRID_ROOT, "summary_official565.json")) or []

    winner = gate.get("best_experiment", "")
    chamfer = gate.get("best_mean_enh_chamfer_distance")
    improve = gate.get("improvement_cg_minus_enh")
    cfg = gate.get("best_config", {})
    voxel = cfg.get("blend_voxel_mm", cfg.get("voxel"))
    fill_r = cfg.get("fill_radius_mm")
    mode = cfg.get("output_mode", "blend_cg")

    lines = [
        "# 后续计划（voxel ≤ 1.0 mm 策略）",
        "",
        f"生成时间: {datetime.now().isoformat(timespec='seconds')}",
        "",
        "## 参数策略",
        "",
        f"- **voxel 上限**: {VOXEL_POLICY_MAX_MM} mm（grid 已证 vx2/vx3/vx4 显著劣于 vx1.0）",
        f"- **推荐 blend voxel**: {RECOMMENDED_BLEND_VX} mm；细搜 0.6 / 0.8 / 1.0",
        "- **优先模式**: `filter_cg` > `filter_blend_cg` > `fill_cg` > `blend_cg`（chamfer 导向）",
        "- **废弃**: 所有 blend vx > 1.0 mm 及旧 submission 默认 vx3.0",
        "",
        "## Gate 结论摘要",
        "",
        f"- **当前胜出**: `{winner}`",
        f"- **ENH chamfer**: {chamfer} mm（官方 CG baseline {CG_BASELINE:.2f} mm）",
        f"- **Δ(CG−ENH)**: {improve} mm（正=优于 CG）",
        f"- **配置**: mode={mode}, voxel={voxel}, fill_radius={fill_r or 'n/a'}",
        f"- **gate_passed**: {gate.get('gate_passed', 'n/a')}",
        "",
    ]

    old_vs = load(
        os.path.join(
            GC2026_ROOT,
            "output/submission_candidate/evaluation_gc_baseline_enh_val565_vs_baseline.json",
        )
    )
    old_ch = None
    if old_vs and "overall" in old_vs:
        old_ch = old_vs["overall"].get("chamfer_distance", {}).get("enh_mean")

    if chamfer is not None and old_ch is not None:
        delta = float(chamfer) - float(old_ch)
        lines.extend([
            "## 与旧 submission (vx3.0 blend) 对比",
            "",
            f"- 旧 submission chamfer: **{old_ch:.4f} mm**",
            f"- 当前 gate winner: **{float(chamfer):.4f} mm**",
            f"- 变化: **{delta:+.4f} mm**",
            "",
        ])

    lines.extend(["## 优先级建议", ""])
    priorities: list[str] = []

    chamfer_done = os.path.isfile(os.path.join(GRID_ROOT, "chamfer_tuned.done"))
    if not chamfer_done:
        priorities.append(
            "1. **【高】完成 chamfer fine grid** — `run_val_grid_chamfer_tuned.sh` "
            f"（仅 vx/fr ≤ {VOXEL_POLICY_MAX_MM} mm：0.6/0.8/1.0 + filter_blend/blend_filter/fill_cg）。"
        )
    else:
        priorities.append(
            "1. **【高】确认 fine grid gate** — 查看 `gate_decision.json` / `summary_official565.csv`。"
        )

    if mode == "filter_cg":
        priorities.append(
            "2. **【高】2155 全量重推理 filter_cg** — 当前最优为 SOR 去噪 CG（非 SuperPC blend）；"
            "运行 `post_gate_2155_infer.sh` 后重打包。"
        )
    elif winner and float(voxel or 99) <= VOXEL_POLICY_MAX_MM:
        priorities.append(
            f"2. **【高】2155 全量重推理** — gate=`{winner}`（vx≤{VOXEL_POLICY_MAX_MM}），"
            "`post_gate_2155_infer.sh` → `build_submission_packages.sh`。"
        )
    else:
        priorities.append(
            f"2. **【高】切换至 vx≤{VOXEL_POLICY_MAX_MM} 配置** — 勿再用 vx3.0；"
            f"默认 blend_voxel_mm={RECOMMENDED_BLEND_VX}。"
        )

    if winner_vs and "overall" in winner_vs:
        ch = winner_vs["overall"].get("chamfer_distance", {})
        if ch.get("improved") is False:
            priorities.append(
                "3. **【中】chamfer 仍差于 CG** — per-sequence 在 0.6–1.0 mm 内微调 "
                "（`build_per_sequence_enh_config.py`）；差序列可 override 为 filter_cg。"
            )

    priorities.append(
        f"4. **【中】清理磁盘** — 可删 vx>1.0 实验目录（vx2/vx3/vx4 及 fill fr≥1.5 非最优组）。"
    )
    priorities.append(
        "5. **【低】Full Pipeline 暂停** — FP chamfer ~124 mm，资源集中 Enh Only。"
    )

    if summary:
        fine = [
            r for r in summary
            if any(x in r.get("experiment", "") for x in ("vx0.6", "vx0.8", "vx1", "fr0.6", "fr0.8", "fr1", "filter"))
        ]
        show = fine[:8] if fine else summary[:8]
        lines.extend([
            "### Grid 排名（fine voxel / 当前全部）",
            "",
            "| rank | experiment | chamfer |",
            "|------|------------|---------|",
        ])
        for i, row in enumerate(show, 1):
            lines.append(
                f"| {i} | `{row.get('experiment','')}` | {row.get('mean_enh_chamfer_distance','')} |"
            )
        lines.append("")

    for p in priorities:
        lines.append(p)
    lines.append("")

    fp_vs = load(
        os.path.join(
            GC2026_ROOT,
            "output/full_pipeline_n0_v2_candidate/evaluation_gc_baseline_fp_val565_vs_baseline.json",
        )
    )
    lines.extend(["## Full Pipeline（参考）", ""])
    if fp_vs and "overall" in fp_vs:
        ch = fp_vs["overall"].get("chamfer_distance", {})
        lines.append(
            f"- FP ENH chamfer **{ch.get('enh_mean', 'n/a')} mm** vs baseline **{ch.get('baseline_mean', 'n/a')} mm**"
        )
    lines.append("")

    os.makedirs(GRID_ROOT, exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print(f"Written: {OUT}")


if __name__ == "__main__":
    main()
