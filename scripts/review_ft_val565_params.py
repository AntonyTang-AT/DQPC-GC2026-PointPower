#!/usr/bin/env python3
"""Compare fine-tune val565 results and suggest param tweaks."""
from __future__ import annotations

import json
import os
from collections import defaultdict

GC2026 = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

BASELINES = {
    "density_submit": "output/enh_refine_p0_p1_p2/pdlts_light_snap1_fill0.6_density/evaluation_gc_baseline_val565.json",
    "region_hybrid_old": "output/enh_refine_val565_selection/region_hybrid_pdlts_superpc_snap1_fill0.6_density/evaluation_gc_baseline_val565.json",
    "pdlts_ft_density": "output/pdlts_finetune_uvg/val565_refine/pdlts_light_snap1_fill0.6_density/evaluation_gc_baseline_val565.json",
    "region_hybrid_ft": "output/ft_val565_fusion/region_hybrid_pdlts_superpc_snap1_fill0.6_density/evaluation_gc_baseline_val565.json",
    "temporal_hybrid_ft": "output/ft_val565_fusion/temporal_region_hybrid_pdlts_superpc_snap1_fill0.6_density/evaluation_gc_baseline_val565.json",
    "temporal_attn_hybrid_ft": "output/ft_val565_fusion/temporal_attn_hybrid_pdlts_superpc_snap1_fill0.6_density/evaluation_gc_baseline_val565.json",
}


def load_cd(path: str) -> float | None:
    p = os.path.join(GC2026, path)
    if not os.path.isfile(p):
        return None
    d = json.load(open(p))
    s = d.get("summary", d)
    return float((s.get("means") or {}).get("chamfer_distance") or s.get("mean_enh_chamfer_distance"))


def per_seq(path: str) -> dict[str, float]:
    p = os.path.join(GC2026, path)
    if not os.path.isfile(p):
        return {}
    d = json.load(open(p))
    rows = d.get("records") or []
    acc: dict[str, list] = defaultdict(list)
    for r in rows:
        seq = r.get("sequence") or ""
        if not seq:
            cg = r.get("cg_path", "")
            for s in ("TrumanShow", "VictoryHeart", "VirtualLife"):
                if f"/{s}/" in cg:
                    seq = s
                    break
        cd = r.get("chamfer_distance")
        if seq and cd is not None:
            acc[seq].append(float(cd))
    return {s: sum(v) / len(v) for s, v in acc.items()}


def main():
    out_dir = os.path.join(GC2026, "output/ft_val565_fusion")
    os.makedirs(out_dir, exist_ok=True)
    rows = []
    for name, rel in BASELINES.items():
        cd = load_cd(rel)
        if cd is not None:
            rows.append({"experiment": name, "chamfer_mm": cd, "per_seq": per_seq(rel)})
    rows.sort(key=lambda r: r["chamfer_mm"])

    recs = []
    base = load_cd(BASELINES["density_submit"]) or 17.504
    ft_d = load_cd(BASELINES["pdlts_ft_density"])
    rh_old = load_cd(BASELINES["region_hybrid_old"])
    rh_ft = load_cd(BASELINES["region_hybrid_ft"])

    if ft_d is not None:
        if ft_d < base - 0.05:
            recs.append("PD-LTS fine-tune density 优于提交基线：可更新 geometry 源为 pdlts_finetune_uvg。")
        elif ft_d > base + 0.05:
            recs.append("PD-LTS fine-tune density 未优于基线：提交仍用冻结 PD-LTS + density preset。")

    if rh_old and rh_ft:
        if rh_ft < rh_old - 0.1:
            recs.append("融合 region hybrid 在 fine-tune 权重下更好：可考虑 region_r_in_mm 维持 25/45。")
        elif rh_ft > rh_old + 0.1:
            recs.append("融合在 fine-tune 权重下变差：建议收紧 region mask（r_in 20mm）或减少 SuperPC fill。")

    if not rh_ft and rh_old and rh_old < base - 0.3:
        recs.append("旧 region hybrid 已显著优于 density；fine-tune 融合跑完后对比再决定是否改 preset。")

    if not recs:
        recs.append("等待全部 eval 完成后重新运行本脚本以生成建议。")

    report = {
        "baseline_density_mm": base,
        "ranking": [{"experiment": r["experiment"], "chamfer_mm": r["chamfer_mm"]} for r in rows],
        "recommendations": recs,
    }
    json_path = os.path.join(out_dir, "param_review.json")
    json.dump(report, open(json_path, "w"), indent=2)

    print("=== Fine-tune val565 参数回顾 ===")
    for r in rows:
        delta = base - r["chamfer_mm"]
        print(f"  {r['experiment']:22s} {r['chamfer_mm']:.3f} mm  (Δ{delta:+.3f})")
    print("\n建议:")
    for line in recs:
        print(f"  - {line}")
    print(f"\n-> {json_path}")


if __name__ == "__main__":
    main()
