#!/usr/bin/env bash
# Live progress: ply count, partial gc_baseline CD, gate tier mix, vs ft / holefill lite.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT_DIR:-$ROOT/output/ft_val565_fusion/holefill_adaptive_frame_gate}"
FT="${FT_DIR:-$ROOT/output/pdlts_finetune_uvg/val565_refine/pdlts_light_snap1_fill0.6_density}"
LITE="${LITE_DIR:-$ROOT/output/ft_val565_fusion/holefill_lite_fill0.25_max10pct_adaptive_post25}"
PAIRS="${PAIRS:-$ROOT/data/processed/val_pairs_official_cgv2.txt}"
PARTIAL_EV="${OUT}/evaluation_partial_val565.json"
WORKERS="${EVAL_WORKERS:-8}"
DO_EVAL="${DO_PARTIAL_EVAL:-0}"

n=$(find "$OUT" -name '*.ply' 2>/dev/null | wc -l)
echo "=== frame_gate val565 $(date +%H:%M:%S) ==="
echo "PLY: $n / 565"

# Gate tier distribution from infer_meta (if any frames done)
meta="$OUT/infer_meta.json"
if [[ -f "$meta" ]]; then
  python3 - <<PY
import json
from collections import Counter
d=json.load(open("$meta"))
frames=d.get("frames", d.get("records", []))
if isinstance(frames, dict):
    frames=list(frames.values())
tiers=Counter()
seq_tiers={}
for fr in frames:
    if not isinstance(fr, dict): continue
    t=fr.get("frame_fill_gate") or fr.get("meta",{}).get("frame_fill_gate")
    if not t: continue
    tiers[t]+=1
    seq=fr.get("sequence") or ""
    if seq:
        seq_tiers.setdefault(seq, Counter())[t]+=1
if tiers:
    print("gate tiers:", dict(tiers), "total", sum(tiers.values()))
    for seq, c in sorted(seq_tiers.items()):
        print(f"  {seq}:", dict(c))
else:
    print("gate tiers: (pending — infer_meta has no frame_fill_gate yet)")
PY
fi

# Partial eval on completed frames only (set DO_PARTIAL_EVAL=0 to skip)
if [[ "$DO_EVAL" == "1" && "$n" -gt 0 ]]; then
  source /root/miniconda3/etc/profile.d/conda.sh
  conda activate superpc 2>/dev/null || true
  nice -n 15 env GC2026_EVAL_PARALLEL=1 OMP_NUM_THREADS=1 \
    python "$ROOT/scripts/evaluate_gc_baseline_metrics.py" \
    --pairs-file "$PAIRS" --test-root "$OUT" --test-mode enh \
    --workers "$WORKERS" --also-cg \
    --out-json "$PARTIAL_EV" \
    --out-csv "${OUT}/evaluation_partial_val565.csv" 2>/dev/null || true
fi

if [[ -f "$PARTIAL_EV" ]]; then
  python3 - <<PY
import json
from collections import defaultdict

def load_cd(path):
    d=json.load(open(path))
    s=d.get("summary", d)
    return s["means"]["chamfer_distance"], s.get("num_evaluated", len(d.get("records",[])))

def per_seq(path):
    d=json.load(open(path))
    acc=defaultdict(list)
    for r in d.get("records", []):
        if r.get("error"): continue
        acc[r["sequence"]].append(float(r["chamfer_distance"]))
    return {k: sum(v)/len(v) for k,v in sorted(acc.items())}

rows=[]
for label, path in [
    ("frame_gate (partial)", "$PARTIAL_EV"),
    ("ft density", "$FT/evaluation_gc_baseline_val565.json"),
    ("holefill lite", "$LITE/evaluation_gc_baseline_val565.json"),
]:
    try:
        cd, nf = load_cd(path)
        rows.append((label, cd, nf))
    except Exception:
        rows.append((label, None, 0))

print("--- Chamfer CD (mm) ---")
for label, cd, nf in rows:
    if cd is None:
        print(f"  {label}: n/a")
    else:
        print(f"  {label}: {cd:.4f}  (n={nf})")

pg = load_cd("$PARTIAL_EV")[0] if rows[0][1] else None
ft = rows[1][1]
lite = rows[2][1]
if pg is not None:
    if ft: print(f"  Δ vs ft:    {pg-ft:+.4f} mm")
    if lite: print(f"  Δ vs lite:  {pg-lite:+.4f} mm")

ps = per_seq("$PARTIAL_EV")
if ps:
    print("--- per-seq (partial) ---")
    for seq, v in ps.items():
        print(f"  {seq}: {v:.4f}")
PY
else
  echo "partial eval: waiting for first PLY"
fi

pgrep -af "holefill_adaptive_frame_gate|frame_gate" 2>/dev/null | grep -v show_ft_frame | head -3 || echo "job: idle or finished"
