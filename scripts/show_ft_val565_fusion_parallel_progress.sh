#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRID="$ROOT/output/ft_val565_fusion"
STATUS="$GRID/parallel_rerun_status.json"
TOTAL=565

python3 - <<PY
import glob, json, os, subprocess, time

root = "$ROOT"
grid = "$GRID"
total = $TOTAL
seqs = ["TrumanShow", "VictoryHeart", "VirtualLife"]
seq_totals = {"TrumanShow": 172, "VictoryHeart": 197, "VirtualLife": 196}
labels = {
    "region_hybrid_pdlts_superpc_snap1_fill0.6_density": "region (ft PD-LTS)",
    "temporal_region_hybrid_pdlts_superpc_snap1_fill0.6_density": "temporal ±2 (ft)",
    "temporal_attn_hybrid_pdlts_superpc_snap1_fill0.6_density": "temporal-attn (ft)",
}

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
if os.path.isfile("$STATUS"):
    phase = json.load(open("$STATUS")).get("phase", phase)

print(f"=== FT 融合并行重跑 ({time.strftime('%Y-%m-%d %H:%M:%S')}) phase={phase} ===")
print("Primary: pdlts_finetune_uvg/val565/light | Secondary: submission_candidate")
print(f"CPU: {os.cpu_count()} 核 | GPU: 不需要 (纯 CPU refine + eval)")
print()

print("任务队列:")
for preset, label in labels.items():
    d = os.path.join(grid, preset)
    c = count(d)
    ev = os.path.join(d, "evaluation_gc_baseline_val565.json")
    if os.path.isfile(ev):
        st = "done"
    elif c["total"] >= total:
        st = "eval"
    elif c["total"] > 0:
        st = f"refine {c['total']}/{total}"
    else:
        st = "pending"
    mark = "▶" if st.startswith("refine") or st == "eval" else ("✓" if st == "done" else "○")
    print(f"  {mark} {label}: {st}")
print()

for preset, label in labels.items():
    d = os.path.join(grid, preset)
    c = count(d)
    ev = os.path.join(d, "evaluation_gc_baseline_val565.json")
    ch = cd(ev)
    pct = 100.0 * c["total"] / total
    chs = f"CD={ch:.3f} mm" if ch else ("eval..." if c["total"] >= total else "")
    print(f"{label}")
    print(f"  {c['total']}/{total} ({pct:.1f}%)  {chs}")
    for s in seqs:
        n, t = c[s], seq_totals[s]
        bar = "█" * int(20 * n / max(t, 1)) + "░" * (20 - int(20 * n / max(t, 1)))
        print(f"    {s:14s} {n:3d}/{t:3d} [{bar}]")
    print()

refs = [
    ("ft density", "output/pdlts_finetune_uvg/val565_refine/pdlts_light_snap1_fill0.6_density/evaluation_gc_baseline_val565.json"),
    ("旧 fusion (frozen, 无效)", "output/enh_refine_val565_selection/region_hybrid_pdlts_superpc_snap1_fill0.6_density/evaluation_gc_baseline_val565.json"),
]
print("参考:")
for name, rel in refs:
    v = cd(os.path.join(root, rel))
    if v:
        print(f"  {name}: {v:.3f} mm")

running = []
for pat in ["run_ft_fusion_one", "run_enh_refine_infer", "evaluate_gc_baseline", "run_ft_val565_fusion_parallel"]:
    r = subprocess.run(["pgrep", "-af", pat], capture_output=True, text=True)
    if r.returncode == 0:
        running.extend(l for l in r.stdout.splitlines() if "show_ft_val565_fusion" not in l)
print(f"\nworkers: {len(running)}")
for line in running[:10]:
    print(f"  {line[:120]}")
PY
