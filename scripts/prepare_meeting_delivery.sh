#!/usr/bin/env bash
# Meeting delivery: val565 gc_baseline CSVs, Excel, reports sync to docs/meeting_delivery (git-tracked).
set -euo pipefail

GC2026_ROOT="${GC2026_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT_DIR="${GC2026_ROOT}/scripts"
DELIVERY_DOCS="${GC2026_ROOT}/docs/meeting_delivery"
DELIVERY_OUT="${GC2026_ROOT}/output/meeting_delivery"
METRICS="${DELIVERY_DOCS}/metrics"
LOG="${DELIVERY_OUT}/prepare.log"
PY="${PY:-python3.12}"
WORKERS="${GC_METRIC_WORKERS:-16}"

mkdir -p "$METRICS" "${DELIVERY_DOCS}/gate_snapshots" "${DELIVERY_OUT}/metrics" "${DELIVERY_OUT}/submission"
exec > >(tee -a "$LOG") 2>&1
echo "[delivery] START $(date -Is)"

progress() { echo "[delivery] PROGRESS $* $(date +%H:%M:%S)"; }

# --- Model paths ---
SUPERPC_JSON="${GC2026_ROOT}/output/submission_candidate/evaluation_gc_baseline_enh_val565.json"
VH_JSON="${GC2026_ROOT}/output/enh_refine_val565_selection/vh_snap0/evaluation_gc_baseline_val565.json"
DENSITY_JSON="${GC2026_ROOT}/output/enh_refine_val565_selection/pdlts_light_snap1_fill0.6_density/evaluation_gc_baseline_val565.json"

SUPERPC_CSV="${METRICS}/01_superpc_blend_cg_kitti360_vx3.0_val565.csv"
VH_CSV="${METRICS}/02_pdlts_vh_snap0_val565.csv"
DENSITY_CSV="${METRICS}/03_pdlts_density_global_snap_no_vh_tune_val565.csv"

export_csv() {
  local tag="$1" json="$2" csv="$3"
  if [[ ! -f "$json" ]]; then
    echo "[delivery] ERROR missing JSON: $json"
    return 1
  fi
  progress "export_csv $tag"
  "$PY" "${SCRIPT_DIR}/export_gc_baseline_csv_from_json.py" \
    --in-json "$json" --out-csv "$csv"
}

progress "parallel_csv_export"
export_csv superpc "$SUPERPC_JSON" "$SUPERPC_CSV" &
PID1=$!
export_csv vh_snap0 "$VH_JSON" "$VH_CSV" &
PID2=$!
export_csv density "$DENSITY_JSON" "$DENSITY_CSV" &
PID3=$!
wait "$PID1" "$PID2" "$PID3"

PDLTS_RAW_JSON="${GC2026_ROOT}/output/pdlts_val565/light/evaluation_gc_baseline_val565.json"
PDLTS_RAW_CSV="${METRICS}/04_pdlts_raw_val565.csv"
SUPERPC_FILTER_CSV="${METRICS}/05_superpc_filter_snap1.0_val565.csv"

if [[ -f "$PDLTS_RAW_JSON" ]]; then
  progress "export_csv pdlts_raw"
  "$PY" "${SCRIPT_DIR}/export_gc_baseline_csv_from_json.py" \
    --in-json "$PDLTS_RAW_JSON" --out-csv "$PDLTS_RAW_CSV"
fi
progress "export_superpc_filter_per_seq"
"$PY" "${SCRIPT_DIR}/export_superpc_filter_per_seq_csv.py" --out-csv "$SUPERPC_FILTER_CSV"

progress "merge_xlsx"
"$PY" "${SCRIPT_DIR}/merge_val565_metrics_xlsx.py"

# Gate snapshots for docs (repo-relative references in reports)
if [[ -f "${GC2026_ROOT}/output/val_grid/gate_decision.json" ]]; then
  cp -f "${GC2026_ROOT}/output/val_grid/gate_decision.json" \
    "${DELIVERY_DOCS}/gate_snapshots/superpc_gate_decision.json"
fi
if [[ -f "${GC2026_ROOT}/output/enh_refine_p0_p1_p2/gate_decision.json" ]]; then
  cp -f "${GC2026_ROOT}/output/enh_refine_p0_p1_p2/gate_decision.json" \
    "${DELIVERY_DOCS}/gate_snapshots/pdlts_gate_decision.json"
fi

if [[ "${FORCE_GC_EVAL:-0}" == "1" ]]; then
  progress "gc_baseline_eval_superpc"
  GC_METRIC_WORKERS="$WORKERS" bash "${SCRIPT_DIR}/run_enh_gc_baseline_metrics.sh" \
    "${GC2026_ROOT}/output/submission_candidate" val565
  cp -f "${GC2026_ROOT}/output/submission_candidate/evaluation_gc_baseline_enh_val565.csv" "$SUPERPC_CSV"
fi

progress "metrics_summary"
GC2026_ROOT="$GC2026_ROOT" "$PY" <<'PY'
import json, os, csv
from collections import defaultdict

GC = os.environ["GC2026_ROOT"]
metrics_dir = os.path.join(GC, "docs/meeting_delivery/metrics")
models = [
    ("superpc_blend_cg", "01_superpc_blend_cg_kitti360_vx3.0_val565.csv"),
    ("pdlts_vh_snap0", "02_pdlts_vh_snap0_val565.csv"),
    ("pdlts_density_no_vh_tune", "03_pdlts_density_global_snap_no_vh_tune_val565.csv"),
    ("pdlts_raw", "04_pdlts_raw_val565.csv"),
]
out = {
    "models": [],
    "cg_baseline_csv": "ACMMM26_GC_baseline.csv",
    "val_sequences": ["TrumanShow", "VictoryHeart", "VirtualLife"],
}
for name, fn in models:
    path = os.path.join("docs/meeting_delivery/metrics", fn)
    full = os.path.join(GC, path)
    if not os.path.isfile(full):
        continue
    rows = list(csv.DictReader(open(full)))
    chamfers = [float(r["chamfer_distance"]) for r in rows]
    by_seq = defaultdict(list)
    for r in rows:
        by_seq[r.get("sequence", "")].append(float(r["chamfer_distance"]))
    out["models"].append({
        "name": name,
        "csv": path,
        "num_frames": len(rows),
        "mean_chamfer_distance": sum(chamfers) / len(chamfers) if chamfers else None,
        "per_sequence_mean_chamfer": {k: sum(v) / len(v) for k, v in sorted(by_seq.items()) if k},
    })
json.dump(out, open(os.path.join(metrics_dir, "summary.json"), "w"), indent=2)
print(json.dumps(out, indent=2))
PY

progress "build_submission_enhancement_only"
bash "${SCRIPT_DIR}/build_pdlts_density_submission.sh"

progress "pack_submission_tar"
tar -czf "${GC2026_ROOT}/output/GC2026_submission_EnhancementOnly.tar.gz" \
  -C "${GC2026_ROOT}/submissions" GC2026_Team_EnhancementOnly
cp -f "${GC2026_ROOT}/output/GC2026_submission_EnhancementOnly.tar.gz" \
  "${DELIVERY_OUT}/submission/GC2026_submission_EnhancementOnly.tar.gz"

progress "refresh_manifest"
OUT_CAND="${GC2026_ROOT}/output/submission_candidate_pdlts_density"
if [[ -d "$OUT_CAND" ]] && find "$OUT_CAND" -name '*.ply' | head -1 | grep -q .; then
  "$PY" "${SCRIPT_DIR}/make_submission.py" \
    --enhanced-dir "$OUT_CAND" \
    --out-dir "${GC2026_ROOT}/submissions/GC2026_Team_EnhancementOnly" \
    --team "GC2026 Team" \
    --processing-track "Enhancement Only" \
    --title "UVG-CWI-DQPC GC2026 Enhancement Only PD-LTS density" \
    --post-processing "${GC2026_ROOT}/output/enh_refine_p0_p1_p2/gate_decision.json" \
    --cg-version v2 \
    --cg-source official \
    --pipeline-notes "Official CGv2 -> PD-LTS light -> snap 1mm + density_adaptive fill 0.6mm"
fi

progress "sync_output_mirror"
rsync -a --delete \
  --exclude='prepare.log' \
  --exclude='submission/' \
  "${DELIVERY_DOCS}/" "${DELIVERY_OUT}/"
cp -f "${LOG}" "${DELIVERY_OUT}/prepare.log" 2>/dev/null || true

echo "[delivery] DONE $(date -Is) docs=${DELIVERY_DOCS}"
