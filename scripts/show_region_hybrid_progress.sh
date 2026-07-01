#!/usr/bin/env bash
# One-shot progress for region / temporal hybrid on val565 (3 sequences).
# Continuous watch: bash scripts/monitor_region_hybrid_val565.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRID="${GRID_ROOT:-$ROOT/output/enh_refine_val565_selection}"
PROGRESS="${PROGRESS:-$GRID/region_hybrid_progress.json}"

python3 - <<PY
import glob, json, os, subprocess, time

root = "$ROOT"
grid = "$GRID"
progress_path = "$PROGRESS"
total = 565
seq_totals = {"TrumanShow": 172, "VictoryHeart": 197, "VirtualLife": 196}
sequences = list(seq_totals.keys())

presets = [
    ("region_hybrid_pdlts_superpc_snap1_fill0.6_density", "spatial mask"),
    ("temporal_region_hybrid_pdlts_superpc_snap1_fill0.6_density", "temporal mask"),
    ("hybrid_pdlts_superpc_snap1_fill0.6_density", "union voxel (baseline)"),
    ("pdlts_light_snap1_fill0.6_density", "density only (submit)"),
]
alt_roots = {
    "pdlts_light_snap1_fill0.6_density": os.path.join(root, "output/enh_refine_p0_p1_p2"),
}

def count_by_seq(d):
    out = {}
    for s in sequences:
        out[s] = len(glob.glob(os.path.join(d, s, "*.ply")))
    out["total"] = sum(out.values())
    return out

def chamfer(ev_path):
    if not os.path.isfile(ev_path):
        return None
    d = json.load(open(ev_path))
    s = d.get("summary", d)
    return (s.get("means") or {}).get("chamfer_distance") or s.get("mean_enh_chamfer_distance")

def per_seq_chamfer(ev_path):
    if not os.path.isfile(ev_path):
        return {}
    d = json.load(open(ev_path))
    rows = d.get("per_frame") or d.get("frames") or []
    if not rows and "records" in d:
        rows = d["records"]
    acc = {s: [] for s in sequences}
    for r in rows:
        seq = r.get("sequence") or ""
        if not seq:
            cg = r.get("cg_path") or r.get("cg") or ""
            for s in sequences:
                if f"/{s}/" in cg:
                    seq = s
                    break
        cd = r.get("chamfer_distance")
        if seq in acc and cd is not None:
            acc[seq].append(float(cd))
    return {s: (sum(v)/len(v) if v else None) for s, v in acc.items()}

running = []
try:
    out = subprocess.check_output(
        ["pgrep", "-af", "run_enh_refine_infer|run_region_hybrid|run_enh_refine_sharded"],
        text=True,
    )
    running = [l.strip() for l in out.splitlines() if "monitor_region_hybrid" not in l][:8]
except subprocess.CalledProcessError:
    pass

jobs = {}
for name, label in presets:
    base = alt_roots.get(name, grid)
    d = os.path.join(base, name)
    ev = os.path.join(d, "evaluation_gc_baseline_val565.json")
    smoke = os.path.join(d, "evaluation_gc_baseline_val565_smoke.json")
    counts = count_by_seq(d)
    jobs[name] = {
        "label": label,
        "counts": counts,
        "pct": round(100.0 * counts["total"] / total, 1),
        "infer_done": os.path.isfile(os.path.join(d, "infer_meta.json")),
        "eval_done": os.path.isfile(ev),
        "chamfer_mm": chamfer(ev) or chamfer(smoke),
        "per_seq_chamfer": per_seq_chamfer(ev),
    }

payload = {
    "updated": time.strftime("%Y-%m-%d %H:%M:%S"),
    "val_sequences": sequences,
    "val_total_frames": total,
    "seq_frame_counts": seq_totals,
    "jobs": jobs,
    "infer_workers": sum(1 for r in running if "run_enh_refine_infer" in r),
    "running_processes": running,
}
json.dump(payload, open(progress_path, "w"), indent=2)

print(f"=== Region Hybrid val565 进度 ({payload['updated']}) ===")
print(f"验证集: {', '.join(sequences)} | 共 {total} 帧")
print(f"后台 worker: {payload['infer_workers']}")
print()
hdr = f"{'preset':52s} {'total':>8s}  {'CD mm':>8s}"
print(hdr)
print("-" * len(hdr))
for name, j in jobs.items():
    c = j["counts"]
    ch = f"{j['chamfer_mm']:.3f}" if j["chamfer_mm"] else "   —"
    st = "✓eval" if j["eval_done"] else f"{j['pct']:5.1f}%"
    print(f"{name:52s} {c['total']:3d}/{total} {st:6s} {ch:>8s}")
    for s in sequences:
        n, t = c[s], seq_totals[s]
        bar = "█" * int(20 * n / t) + "░" * (20 - int(20 * n / t))
        print(f"  {s:14s} {n:3d}/{t:3d} [{bar}]")
print()
print(f"进度 JSON: {progress_path}")
if running:
    print("运行中:")
    for r in running:
        print(f"  {r[:120]}")
PY
