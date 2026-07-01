#!/usr/bin/env bash
# Official-style val565 eval: gc_baseline (aligned, full points) + Metric repo chamfer-L1 (20k).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAIRS="${PAIRS_FILE:-$ROOT/data/processed/val_pairs_official_cgv2.txt}"
OUT="$ROOT/output/enh_refine_val565_selection/official_eval"
WORKERS="${WORKERS:-24}"
mkdir -p "$OUT"

run_pair() {
  local tag="$1" root="$2"
  echo "[$(date +%H:%M:%S)] gc_baseline $tag"
  python "$ROOT/scripts/evaluate_gc_baseline_metrics.py" \
    --pairs-file "$PAIRS" --test-root "$root" --test-mode enh \
    --workers "$WORKERS" --also-cg \
    --out-json "$OUT/${tag}_gc_baseline_val565.json" \
    >"$OUT/${tag}_gc_baseline.log" 2>&1 &
  echo "[$(date +%H:%M:%S)] official_metric $tag"
  python "$ROOT/scripts/evaluate_official_metric.py" \
    --pairs-file "$PAIRS" --enhanced-root "$root" \
    --max-points 20000 --also-cg \
    --out-json "$OUT/${tag}_official_metric_val565.json" \
    >"$OUT/${tag}_official_metric.log" 2>&1 &
}

run_pair vh_snap0 "$ROOT/output/enh_refine_val565_selection/vh_snap0"
run_pair density "$ROOT/output/enh_refine_p0_p1_p2/pdlts_light_snap1_fill0.6_density"
run_pair superpc "$ROOT/output/submission_candidate"

wait
echo "[$(date +%H:%M:%S)] ALL DONE"

python3 - <<PY
import json, os
out = "$OUT"
rows = []
for tag in ["vh_snap0", "density", "superpc"]:
    gc = os.path.join(out, f"{tag}_gc_baseline_val565.json")
    om = os.path.join(out, f"{tag}_official_metric_val565.json")
    if not os.path.isfile(gc):
        continue
    g = json.load(open(gc))["summary"]
    o = json.load(open(om))["summary"] if os.path.isfile(om) else {}
    rows.append({
        "tag": tag,
        "gc_chamfer": g["means"]["chamfer_distance"],
        "gc_cg": g.get("mean_cg_chamfer_distance"),
        "gc_improve": g.get("mean_improvement_cg_minus_enh"),
        "metric_L1": o.get("mean_enh_chamfer-L1"),
        "metric_cg_L1": o.get("mean_cg_chamfer-L1"),
        "metric_improve": o.get("mean_improvement_cg_minus_enh"),
        "metric_L2old": (o.get("mean_enh_chamfer-L1") or 0) / 2 if o else None,
    })
print(f"{'model':<12} {'gc_baseline':>12} {'vs CG':>10} | {'chamfer-L1':>12} {'vs CG':>10} | {'L2old':>10}")
for r in rows:
    print(f"{r['tag']:<12} {r['gc_chamfer']:12.4f} {r['gc_improve']:+10.4f} | {r['metric_L1']:12.4f} {r['metric_improve']:+10.4f} | {r['metric_L2old']:10.4f}")
with open(os.path.join(out, "comparison_val565.json"), "w") as f:
    json.dump(rows, f, indent=2)
PY
