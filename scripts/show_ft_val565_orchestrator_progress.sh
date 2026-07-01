#!/usr/bin/env bash
# Unified progress for fine-tune val565 orchestrator.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORCH="$ROOT/output/ft_val565_orchestrator/orchestrator_status.json"
PDLTS_GEOM="$ROOT/output/pdlts_finetune_uvg/val565/light"
PDLTS_REF="$ROOT/output/pdlts_finetune_uvg/val565_refine/pdlts_light_snap1_fill0.6_density"
SUPERPC="${SUPERPC_GEOM:-$ROOT/output/submission_candidate}"
FUSION="$ROOT/output/ft_val565_fusion"
TOTAL=565

python3 - <<PY
import glob, json, os, subprocess, time

root = "$ROOT"
total = $TOTAL
seqs = ["TrumanShow", "VictoryHeart", "VirtualLife"]
seq_totals = {"TrumanShow": 172, "VictoryHeart": 197, "VirtualLife": 196}

def count(d):
    if not os.path.isdir(d):
        return {s: 0 for s in seqs} | {"total": 0}
    out = {s: len(glob.glob(os.path.join(d, s, "*.ply"))) for s in seqs}
    out["total"] = sum(out.values())
    return out

def cd(path):
    if not os.path.isfile(path):
        return None
    d = json.load(open(path))
    s = d.get("summary", d)
    return (s.get("means") or {}).get("chamfer_distance") or s.get("mean_enh_chamfer_distance")

phase = "unknown"
if os.path.isfile("$ORCH"):
    phase = json.load(open("$ORCH")).get("phase", phase)

stages = [
    ("PD-LTS infer (ft ckpt)", "$PDLTS_GEOM", None),
    ("PD-LTS refine+density", "$PDLTS_REF", "$PDLTS_REF/evaluation_gc_baseline_val565.json"),
    ("SuperPC secondary (submission, 复用)", "$SUPERPC", None),
    ("Fusion region (ft weights)", "$FUSION/region_hybrid_pdlts_superpc_snap1_fill0.6_density",
     "$FUSION/region_hybrid_pdlts_superpc_snap1_fill0.6_density/evaluation_gc_baseline_val565.json"),
    ("Fusion temporal (ft, ±2帧 CG)", "$FUSION/temporal_region_hybrid_pdlts_superpc_snap1_fill0.6_density",
     "$FUSION/temporal_region_hybrid_pdlts_superpc_snap1_fill0.6_density/evaluation_gc_baseline_val565.json"),
    ("Fusion temporal-attn (ft, 最后)", "$FUSION/temporal_attn_hybrid_pdlts_superpc_snap1_fill0.6_density",
     "$FUSION/temporal_attn_hybrid_pdlts_superpc_snap1_fill0.6_density/evaluation_gc_baseline_val565.json"),
]

print(f"=== FT val565 总编排进度 ({time.strftime('%Y-%m-%d %H:%M:%S')}) ===")
print(f"phase: {phase}")
print(f"说明: SuperPC 复用 submission_candidate; temporal-attn 用 ft density 作 ENH history")
print()

print("任务队列:")
for i, (label, dirpath, ev) in enumerate(stages, 1):
    c = count(dirpath)
    if ev and os.path.isfile(ev):
        st = "done"
    elif c["total"] >= total:
        st = "eval pending" if ev else "done"
    elif c["total"] > 0:
        st = f"running {c['total']}/{total}"
    else:
        st = "pending"
    mark = "▶" if st.startswith("running") else ("✓" if st == "done" else "○")
    print(f"  {i}. {mark} {label}: {st}")
print()

for label, dirpath, ev in stages:
    c = count(dirpath)
    pct = 100.0 * c["total"] / total
    ch = cd(ev) if ev else None
    chs = f"CD={ch:.3f}" if ch else ("eval..." if c["total"] >= total and ev else "")
    print(f"{label}")
    print(f"  {c['total']}/{total} ({pct:.1f}%)  {chs}")
    for s in seqs:
        n, t = c[s], seq_totals[s]
        bar = "█" * int(20 * n / max(t, 1)) + "░" * (20 - int(20 * n / max(t, 1)))
        print(f"    {s:14s} {n:3d}/{t:3d} [{bar}]")

print()
refs = [
    ("density 基线", "output/enh_refine_p0_p1_p2/pdlts_light_snap1_fill0.6_density/evaluation_gc_baseline_val565.json"),
    ("region hybrid 旧", "output/enh_refine_val565_selection/region_hybrid_pdlts_superpc_snap1_fill0.6_density/evaluation_gc_baseline_val565.json"),
]
print("参考 CD:")
for name, rel in refs:
    v = cd(os.path.join(root, rel))
    if v:
        print(f"  {name}: {v:.3f} mm")

running = []
for pat in ["run_pdlts_finetune_val565", "run_pdlts_infer", "run_superpc_infer", "run_ft_val565", "run_enh_refine", "evaluate_gc_baseline", "run_ft_val565_orchestrator"]:
    try:
        r = subprocess.run(["pgrep", "-af", pat], capture_output=True, text=True)
        if r.returncode == 0:
            running.extend(l.strip() for l in r.stdout.splitlines() if "show_ft_val565" not in l)
    except Exception:
        pass
running = running[:8]
print(f"\nworkers: {len(running)}")
for line in running:
    print(f"  {line[:115]}")

review = os.path.join(root, "output/ft_val565_fusion/param_review.json")
if os.path.isfile(review):
    recs = json.load(open(review)).get("recommendations", [])
    if recs:
        print("\n参数建议 (param_review.json):")
        for r in recs[:5]:
            print(f"  - {r}")
PY
