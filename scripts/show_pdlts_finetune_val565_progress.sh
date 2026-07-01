#!/usr/bin/env bash
# Progress for fine-tuned PD-LTS val565 pipeline (infer → refine → eval).
#
#   bash scripts/show_pdlts_finetune_val565_progress.sh
#   watch -n 30 bash scripts/show_pdlts_finetune_val565_progress.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="${PDLTS_FT_ROOT:-$ROOT/output/pdlts_finetune_uvg}"
STATUS="${STATUS:-$BASE/pipeline_status.json}"
GEOM_DIR="${GEOM_DIR:-$BASE/val565/light}"
REFINE_OUT="${REFINE_OUT:-$BASE/val565_refine/pdlts_light_snap1_fill0.6_density}"
TOTAL=565

python3 - <<PY
import glob, json, os, subprocess, time

base = "$BASE"
status_path = "$STATUS"
geom = "$GEOM_DIR"
refine = "$REFINE_OUT"
total = $TOTAL
seqs = ["TrumanShow", "VictoryHeart", "VirtualLife"]
seq_totals = {"TrumanShow": 172, "VictoryHeart": 197, "VirtualLife": 196}
baseline_cd = 17.504

def count_by_seq(d):
    out = {s: len(glob.glob(os.path.join(d, s, "*.ply"))) for s in seqs}
    out["total"] = sum(out.values())
    return out

def tail_log(path, n=2):
    if not os.path.isfile(path):
        return ""
    lines = open(path, errors="replace").read().replace("\r", "\n").splitlines()
    return lines[-n:] if lines else []

def running_procs():
    pats = [
        "run_pdlts_infer.py.*val565",
        "run_enh_refine_infer.py.*val565_refine",
        "run_pdlts_finetune_val565_pipeline",
        "evaluate_gc_baseline.*val565_refine",
    ]
    out = []
    for p in pats:
        try:
            r = subprocess.run(["pgrep", "-af", p], capture_output=True, text=True)
            if r.returncode == 0:
                out.extend(l.strip() for l in r.stdout.splitlines() if "show_pdlts_finetune" not in l)
        except Exception:
            pass
    return out[:10]

phase = "unknown"
ckpt = ""
ch = None
if os.path.isfile(status_path):
    st = json.load(open(status_path))
    phase = st.get("phase", phase)
    ckpt = st.get("ckpt", ckpt)
    ch = st.get("chamfer_mm")

pdlts = count_by_seq(geom)
ref = count_by_seq(refine)
ev = os.path.join(refine, "evaluation_gc_baseline_val565.json")
if ch is None and os.path.isfile(ev):
    d = json.load(open(ev))
    s = d.get("summary", d)
    ch = (s.get("means") or {}).get("chamfer_distance") or s.get("mean_enh_chamfer_distance")

payload = {
    "updated": time.strftime("%Y-%m-%d %H:%M:%S"),
    "phase": phase,
    "ckpt": ckpt,
    "pdlts_infer": pdlts,
    "refine": ref,
    "eval_done": os.path.isfile(ev),
    "chamfer_mm": ch,
    "running": running_procs(),
}
json.dump(payload, open(status_path, "w"), indent=2)

print(f"=== PD-LTS Fine-tune val565 Pipeline ({payload['updated']}) ===")
print(f"phase: {phase}")
if ckpt:
    print(f"ckpt:  {ckpt}")
print()

def bar(n, t):
    filled = int(20 * n / t) if t else 0
    return "█" * filled + "░" * (20 - filled)

print(f"{'stage':14s} {'progress':>12s}  {'pct':>6s}")
print("-" * 36)
for label, counts in [("PD-LTS infer", pdlts), ("refine+density", ref)]:
    pct = 100.0 * counts["total"] / total
    print(f"{label:14s} {counts['total']:3d}/{total} {pct:5.1f}%")
    for s in seqs:
        n, t = counts[s], seq_totals[s]
        print(f"  {s:14s} {n:3d}/{t:3d} [{bar(n,t)}]")

print()
if ch is not None:
    delta = baseline_cd - float(ch)
    print(f"eval CD: {float(ch):.3f} mm  (vs density {baseline_cd:.3f}, Δ{delta:+.3f})")
elif os.path.isfile(os.path.join(base, "logs/pipeline/eval.log")):
    for ln in tail_log(os.path.join(base, "logs/pipeline/eval.log"), 1):
        if "gc_metrics:" in ln:
            print(f"eval: {ln.strip()[:90]}")
else:
    print("eval: pending")

print(f"\nstatus JSON: {status_path}")
running = payload["running"]
print(f"workers: {len(running)}")
for r in running:
    print(f"  {r[:115]}")
PY
