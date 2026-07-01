#!/usr/bin/env bash
# Poll val565 selection progress; writes progress.json every INTERVAL sec.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRID="${GRID_ROOT:-$ROOT/output/enh_refine_val565_selection}"
TOTAL=565
INTERVAL="${INTERVAL:-30}"
PROGRESS="$GRID/progress.json"

while true; do
  python3 - <<PY
import json, os, glob, time, subprocess
grid = "$GRID"
total = $TOTAL
jobs = {}

def count_ply(d):
    if not os.path.isdir(d):
        return 0
    return sum(1 for _ in glob.iglob(os.path.join(d, "*", "*.ply")))

def chamfer(ev_path):
    if not os.path.isfile(ev_path):
        return None
    d = json.load(open(ev_path))
    s = d.get("summary", d)
    return (s.get("means") or {}).get("chamfer_distance") or s.get("mean_enh_chamfer_distance")

experiments = [
    ("pdlts_light_snap1_fill0.6_density", "baseline"),
    ("density_temporal_w3", "temporal"),
    ("density_temporal_w5", "temporal"),
    ("hybrid_pdlts_superpc_snap1_fill0.6_density", "infer"),
    ("hybrid_pdlts_superpc_snap1_fill0.6_superfill", "infer"),
    ("fp_migrated_pre25_density", "infer"),
]

for name, kind in experiments:
    d = os.path.join(grid, name)
    ev = os.path.join(d, "evaluation_gc_baseline_val565.json")
    infer_done = os.path.isfile(os.path.join(d, "infer_meta.json"))
    jobs[name] = {
        "kind": kind,
        "ply": count_ply(d),
        "total": total,
        "pct": round(100.0 * count_ply(d) / total, 1),
        "infer_done": infer_done,
        "eval_done": os.path.isfile(ev),
        "chamfer_mm": chamfer(ev),
    }

# log tails
logs = {}
for lf in glob.glob(os.path.join(grid, "logs", "*.log")):
    name = os.path.basename(lf).replace(".log", "")
    try:
        with open(lf) as f:
            lines = f.readlines()
        logs[name] = "".join(lines[-3:]).strip()
    except OSError:
        pass

running = []
try:
    out = subprocess.check_output(["pgrep", "-af", "run_enh_refine_infer|evaluate_gc_baseline"], text=True)
    running = [l.strip() for l in out.splitlines() if "monitor_val565" not in l][:12]
except subprocess.CalledProcessError:
    pass
infer_workers = sum(1 for r in running if "run_enh_refine_infer" in r)

payload = {
    "updated": time.strftime("%Y-%m-%d %H:%M:%S"),
    "jobs": jobs,
    "infer_workers": infer_workers,
    "running_processes": running,
    "log_tail": logs,
}
json.dump(payload, open("$PROGRESS", "w"), indent=2)

done_infer = sum(1 for j in jobs.values() if j["kind"] == "infer" and j["infer_done"])
done_eval = sum(1 for j in jobs.values() if j["eval_done"])
print(f"[{payload['updated']}] eval={done_eval}/{len(jobs)} infer_workers={infer_workers}")
for name, j in jobs.items():
    ch = f"{j['chamfer_mm']:.4f}" if j['chamfer_mm'] else "—"
    st = "EVAL" if j["eval_done"] else ("INF+" if j["infer_done"] else f"{j['pct']}%")
    print(f"  {name:45s} {j['ply']:3d}/{total} {st:5s} chamfer={ch}")
PY
  sleep "$INTERVAL"
done
