#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="${BASE:-$ROOT/output/ft_val565_fusion}"
A="${OUT_A:-$BASE/holefill_secondary_cg_snap1_fill0.6_density}"
B="${OUT_B:-$BASE/holefill_first_fill0.6_post25_density}"
FT="${FT_DIR:-$ROOT/output/pdlts_finetune_uvg/val565_refine/pdlts_light_snap1_fill0.6_density}"

count_ply() { find "$1" -name '*.ply' 2>/dev/null | wc -l; }

na=$(count_ply "$A")
nb=$(count_ply "$B")
echo "holefill secondary (snap->fill): $na / 565"
echo "holefill first (fill->snap->post25): $nb / 565"

for pair in "A:$A" "B:$B"; do
  label="${pair%%:*}"
  out="${pair#*:}"
  ev="$out/evaluation_gc_baseline_val565.json"
  if [[ -f "$ev" ]]; then
    python3 - <<PY
import json
try:
    d=json.load(open("$ev"))
    print("$label CD", d.get("means", {}).get("chamfer_distance", "n/a"))
except Exception as e:
    print("$label eval error", e)
PY
  fi
done

ft_ev="$FT/evaluation_gc_baseline_val565.json"
if [[ -f "$ft_ev" ]]; then
  python3 - <<PY
import json
d=json.load(open("$ft_ev"))
print("ft density baseline CD", d["means"]["chamfer_distance"])
PY
fi

pgrep -af "holefill|run_ft_fusion_one|run_enh_refine_infer" 2>/dev/null | head -5 || true
