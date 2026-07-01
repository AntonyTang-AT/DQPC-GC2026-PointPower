#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${DEST:-$ROOT/output/ft_val565_candidate}"
python3 - <<PY
import glob, json, os, time
dest = os.path.realpath("$DEST") if os.path.islink("$DEST") or os.path.isdir("$DEST") else "$DEST"
seqs = ["TrumanShow", "VictoryHeart", "VirtualLife"]
totals = {"TrumanShow": 172, "VictoryHeart": 197, "VirtualLife": 196}
print(f"=== FT val565 正确 ENH 候选 ({time.strftime('%Y-%m-%d %H:%M:%S')}) ===")
print(f"path: {dest}")
if os.path.isfile(os.path.join(dest, "manifest.json")):
    m = json.load(open(os.path.join(dest, "manifest.json")))
    print(f"preset: {m.get('pipeline',{}).get('refine_preset')}")
    print(f"ckpt:   {m.get('pipeline',{}).get('pdlts_ckpt','')[-60:]}")
    cd = (m.get('eval') or {}).get('chamfer_mm')
    if cd: print(f"CD:     {cd:.3f} mm (val565)")
for s in seqs:
    n = len(glob.glob(os.path.join(dest, s, "*.ply")))
    t = totals[s]
    bar = "█" * int(20 * n / max(t, 1)) + "░" * (20 - int(20 * n / max(t, 1)))
    print(f"  {s:14s} {n:3d}/{t:3d} [{bar}]")
print(f"  total {sum(len(glob.glob(os.path.join(dest,s,'*.ply'))) for s in seqs)}/565")
PY
