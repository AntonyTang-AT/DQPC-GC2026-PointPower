#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT_DIR:-$ROOT/output/ft_val565_fusion/holefill_lite_fill0.25_max10pct_adaptive_post25}"
FT="${FT_DIR:-$ROOT/output/pdlts_finetune_uvg/val565_refine/pdlts_light_snap1_fill0.6_density}"
n=$(find "$OUT" -name '*.ply' 2>/dev/null | wc -l)
echo "holefill lite: $n / 565"
ev="$OUT/evaluation_gc_baseline_val565.json"
if [[ -f "$ev" ]]; then
  python3 - <<PY
import json
for label, path in [
    ("lite", "$ev"),
    ("ft density", "$FT/evaluation_gc_baseline_val565.json"),
]:
    d=json.load(open(path))
    s=d.get("summary", d)
    print(label, "CD", round(s["means"]["chamfer_distance"], 4))
PY
else
  echo "eval: pending"
fi
pgrep -af "holefill_lite|holefill_lite_fill0.25" 2>/dev/null | head -3 || true
