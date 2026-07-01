#!/usr/bin/env bash
# Re-run temporal smooth (CG-displacement fix) + eval on val565 winners.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRID="${GRID_ROOT:-$ROOT/output/enh_refine_val565_selection}"
CG_ROOT="${CG_ROOT:-$ROOT/data/raw/UVG-CWI-DQPC}"
PAIRS="${PAIRS_FILE:-$ROOT/data/processed/val_pairs_official_cgv2.txt}"
PY="${PY:-python3}"
LOG_DIR="$GRID/logs"
mkdir -p "$LOG_DIR"

run_one() {
  local in_dir="$1" win="$2" tag="$3"
  local out_dir="$GRID/${tag}_temporal_w${win}"
  local log="$LOG_DIR/${tag}_temporal_w${win}_fixed.log"
  echo "[$(date +%H:%M:%S)] START temporal w=$win in=$in_dir -> $out_dir" | tee "$log"
  EVAL=1 TEMPORAL_WINDOW="$win" CG_ROOT="$CG_ROOT" PAIRS_FILE="$PAIRS" \
    bash "$ROOT/scripts/run_enh_cpu_post.sh" "$in_dir" "$out_dir" >>"$log" 2>&1
  echo "[$(date +%H:%M:%S)] DONE $out_dir" | tee -a "$log"
}

# density champion + current winner vh_snap0; w3 and w5 in parallel
IN_DENSITY="$ROOT/output/enh_refine_p0_p1_p2/pdlts_light_snap1_fill0.6_density"
IN_VH="$GRID/vh_snap0"

pids=()
run_one "$IN_DENSITY" 3 density &
pids+=($!)
run_one "$IN_DENSITY" 5 density &
pids+=($!)
run_one "$IN_VH" 3 vh_snap0 &
pids+=($!)
run_one "$IN_VH" 5 vh_snap0 &
pids+=($!)

fail=0
for pid in "${pids[@]}"; do
  wait "$pid" || fail=1
done

echo "[$(date +%H:%M:%S)] ALL temporal jobs finished fail=$fail" | tee "$LOG_DIR/temporal_fix_summary.log"
"$PY" - <<PY
import json, os
g = "$GRID"
rows = []
for name in sorted(os.listdir(g)):
    if "_temporal_w" not in name:
        continue
    ev = os.path.join(g, name, "evaluation_gc_baseline_val565.json")
    meta = os.path.join(g, name, "temporal_smooth_meta.json")
    if not os.path.isfile(ev):
        continue
    ch = json.load(open(ev))["summary"]["means"]["chamfer_distance"]
    m = json.load(open(meta)) if os.path.isfile(meta) else {}
    rows.append((ch, name, m.get("frames_smoothed"), m.get("max_correction_mm")))
for ch, name, fs, mc in sorted(rows):
    print(f"{name}: chamfer={ch:.6f} smoothed_frames={fs} max_corr={mc}")
PY

exit "$fail"
