#!/usr/bin/env python3
"""Generate MORNING_REPORT.md from fast grid + baseline comparison outputs."""
from __future__ import annotations

import csv
import json
import os
from datetime import datetime

GC2026_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GRID_ROOT = os.path.join(GC2026_ROOT, "output/val_grid_official565")
OUT_PATH = os.path.join(GRID_ROOT, "MORNING_REPORT.md")

METRICS = [
    ("chamfer_distance", "mm", "lower"),
    ("accuracy", "mm", "lower"),
    ("completeness", "mm", "lower"),
    ("hausdorff_distance", "mm", "lower"),
    ("precision_10.0", "", "higher"),
    ("recall_10.0", "", "higher"),
    ("fscore_10.0", "", "higher"),
]


def load_json(path: str) -> dict | None:
    if not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def fmt(v, unit: str) -> str:
    if v is None:
        return "n/a"
    if unit == "mm":
        return f"{float(v):.2f} mm"
    return f"{float(v):.4f}"


def main() -> None:
    gate = load_json(os.path.join(GRID_ROOT, "gate_decision.json")) or {}
    winner_vs = load_json(os.path.join(GRID_ROOT, "winner_vs_baseline.json"))
    old_sub = load_json(
        os.path.join(GC2026_ROOT, "output/submission_candidate/evaluation_gc_baseline_enh_val565_vs_baseline.json")
    )
    fp_vs = load_json(
        os.path.join(
            GC2026_ROOT,
            "output/full_pipeline_n0_v2_candidate/evaluation_gc_baseline_fp_val565_vs_baseline.json",
        )
    )

    summary_rows: list[dict] = []
    csv_path = os.path.join(GRID_ROOT, "summary_official565.csv")
    if os.path.isfile(csv_path):
        with open(csv_path, encoding="utf-8") as f:
            summary_rows = list(csv.DictReader(f))

    lines = [
        "# Enh Grid 明早指标汇报",
        "",
        f"生成时间: {datetime.now().isoformat(timespec='seconds')}",
        "",
        "## Gate 结论",
        "",
    ]

    if gate:
        lines.extend([
            f"- **胜出实验**: `{gate.get('best_experiment', gate.get('selected_experiment', 'n/a'))}`",
            f"- **chamfer_distance**: {gate.get('best_mean_enh_chamfer_distance', 'n/a')} mm",
            f"- **CG baseline**: {gate.get('cg_baseline_chamfer_distance', 'n/a')} mm",
            f"- **improvement vs CG**: {gate.get('improvement_vs_cg_baseline_mm', 'n/a')} mm",
            f"- **gate pass**: {gate.get('pass', 'n/a')}",
            "",
        ])
    else:
        lines.append("- gate_decision.json 尚未生成\n")

    lines.extend(["## 5 组 Grid 排名（chamfer_distance 升序）", ""])
    if summary_rows:
        ranked = sorted(
            summary_rows,
            key=lambda r: float(r.get("mean_enh_chamfer_distance") or 9999),
        )
        lines.append("| rank | experiment | chamfer | fscore@10 | vs CG |")
        lines.append("|------|------------|---------|-----------|-------|")
        for i, row in enumerate(ranked, 1):
            lines.append(
                f"| {i} | `{row.get('experiment','')}` | "
                f"{row.get('mean_enh_chamfer_distance','')} | "
                f"{row.get('mean_fscore_10.0', row.get('mean_fscore_10',''))} | "
                f"{row.get('mean_improvement_cg_minus_enh','')} |"
            )
        lines.append("")
    else:
        lines.append("_summary_official565.csv 尚未生成_\n")

    def metric_table(vs_data: dict | None, title: str) -> list[str]:
        out = [f"## {title}", ""]
        if not vs_data or "overall" not in vs_data:
            out.append("_数据尚未就绪_\n")
            return out
        overall = vs_data["overall"]
        out.append("| 指标 | baseline | ENH | delta | 更好? |")
        out.append("|------|----------|-----|-------|-------|")
        for key, unit, direction in METRICS:
            block = overall.get(key)
            if not block:
                continue
            b = block.get("baseline_mean")
            e = block.get("enh_mean")
            d = block.get("delta_enh_minus_baseline")
            improved = block.get("improved", False)
            mark = "yes" if improved else "no"
            out.append(
                f"| {key} | {fmt(b, unit)} | {fmt(e, unit)} | "
                f"{fmt(d, unit) if d is not None else 'n/a'} | {mark} |"
            )
        out.append("")
        return out

    lines.extend(metric_table(winner_vs, "Winner vs 官方 Baseline（7 项指标）"))
    lines.extend(metric_table(old_sub, "对照：当前 submission vx3.0 vs Baseline"))

    lines.extend(["## Full Pipeline val565（并行评估）", ""])
    if fp_vs and "overall" in fp_vs:
        ch = fp_vs["overall"].get("chamfer_distance", {})
        fs = fp_vs["overall"].get("fscore_10.0", {})
        lines.extend([
            f"- FP ENH chamfer: {fmt(ch.get('enh_mean'), 'mm')} "
            f"(baseline {fmt(ch.get('baseline_mean'), 'mm')})",
            f"- FP ENH fscore@10: {fmt(fs.get('enh_mean'), '')} "
            f"(baseline {fmt(fs.get('baseline_mean'), '')})",
            "",
        ])
    else:
        lines.append("_FP eval 尚未完成 — 见 output/full_pipeline_gc_baseline_eval.log_\n")

    lines.extend([
        "## 文件索引",
        "",
        f"- `{GRID_ROOT}/gate_decision.json`",
        f"- `{GRID_ROOT}/summary_official565.csv`",
        f"- `{GRID_ROOT}/winner_vs_baseline.json`",
        "",
    ])

    os.makedirs(GRID_ROOT, exist_ok=True)
    with open(OUT_PATH, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print(f"Written: {OUT_PATH}")


if __name__ == "__main__":
    main()
