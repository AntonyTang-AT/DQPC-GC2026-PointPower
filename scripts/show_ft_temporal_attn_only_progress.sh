#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/output/ft_val565_fusion/temporal_attn_hybrid_pdlts_superpc_snap1_fill0.6_density"
STATUS="$ROOT/output/ft_val565_fusion/temporal_attn_only_status.json"
TOTAL=565
python3 - <<PY
import glob, json, os, subprocess, time
out = "$OUT"
total = $TOTAL
seqs = ["TrumanShow", "VictoryHeart", "VirtualLife"]
st = {"TrumanShow":172,"VictoryHeart":197,"VirtualLife":196}
phase = "unknown"; cd = None
if os.path.isfile("$STATUS"):
    d = json.load(open("$STATUS")); phase = d.get("phase", phase); cd = d.get("chamfer_mm")
ev = os.path.join(out, "evaluation_gc_baseline_val565.json")
if cd is None and os.path.isfile(ev):
    s = json.load(open(ev)).get("summary", {})
    cd = (s.get("means") or {}).get("chamfer_distance")
print(f"=== temporal-attn only (ft) {time.strftime('%H:%M:%S')} phase={phase} ===")
print(f"out: {out}")
counts = {s: len(glob.glob(os.path.join(out,s,'*.ply'))) for s in seqs}
n = sum(counts.values())
pct = 100*n/total
chs = f"CD={cd:.3f} mm" if cd else ("eval..." if n>=total else "")
print(f"progress: {n}/{total} ({pct:.1f}%)  {chs}")
for s in seqs:
    a,b=counts[s],st[s]
    bar = "█"*int(20*a/max(b,1)) + "░"*(20-int(20*a/max(b,1)))
    print(f"  {s:14s} {a:3d}/{b:3d} [{bar}]")
refs = [
 ("ft density (正确ft)", "output/pdlts_finetune_uvg/val565_refine/pdlts_light_snap1_fill0.6_density/evaluation_gc_baseline_val565.json"),
 ("旧 region fusion", "output/enh_refine_val565_selection/region_hybrid_pdlts_superpc_snap1_fill0.6_density/evaluation_gc_baseline_val565.json"),
]
print("\n参考:")
for name, rel in refs:
    p=os.path.join("$ROOT", rel)
    if os.path.isfile(p):
        s=json.load(open(p)).get("summary",{})
        v=(s.get("means") or {}).get("chamfer_distance")
        if v: print(f"  {name}: {float(v):.3f} mm")
r = subprocess.run(["pgrep","-af","temporal_attn_hybrid"], capture_output=True, text=True)
lines=[l for l in r.stdout.splitlines() if "show_ft_temporal" not in l] if r.returncode==0 else []
print(f"\nworkers: {len(lines)}")
for l in lines[:6]: print(f"  {l[:115]}")
rem=total-n
if n>0 and n<total:
    print(f"\n预计剩余 refine ~{max(15, int(rem*0.15))}–{max(25,int(rem*0.25))} min (单路独占 CPU)")
elif n>=total and not os.path.isfile(ev):
    print("\n预计 eval ~10–15 min")
PY
