#!/usr/bin/env bash
# Regenerate meeting_delivery for holefill lite (ft PD-LTS + SuperPC CG-hole hybrid).
set -euo pipefail

GC2026_ROOT="${GC2026_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT_DIR="${GC2026_ROOT}/scripts"
DELIVERY_DOCS="${GC2026_ROOT}/docs/meeting_delivery"
DELIVERY_OUT="${GC2026_ROOT}/output/meeting_delivery"
METRICS="${DELIVERY_DOCS}/metrics"
LOG="${DELIVERY_OUT}/prepare_holefill_lite.log"
PY="${PY:-python3}"

mkdir -p "$METRICS" "${DELIVERY_DOCS}/gate_snapshots" "${DELIVERY_OUT}/metrics" \
  "${DELIVERY_DOCS}/figures" "${DELIVERY_OUT}/figures"
exec > >(tee -a "$LOG") 2>&1
echo "[delivery-lite] START $(date -Is)"

progress() { echo "[delivery-lite] $* $(date +%H:%M:%S)"; }

HOLEFILL_JSON="${GC2026_ROOT}/output/ft_val565_fusion/holefill_lite_fill0.25_max10pct_adaptive_post25/evaluation_gc_baseline_val565.json"
FT_JSON="${GC2026_ROOT}/output/pdlts_finetune_uvg/val565_refine/pdlts_light_snap1_fill0.6_density/evaluation_gc_baseline_val565.json"
LINEB_JSON="${GC2026_ROOT}/output/ft_val565_fusion/holefill_first_fill0.6_post25_density/evaluation_gc_baseline_val565.json"
SUPERPC_JSON="${GC2026_ROOT}/output/submission_candidate/evaluation_gc_baseline_enh_val565.json"

export_csv() {
  local tag="$1" json="$2" csv="$3"
  [[ -f "$json" ]] || { echo "[delivery-lite] WARN missing $json"; return 0; }
  progress "export_csv $tag"
  "$PY" "${SCRIPT_DIR}/export_gc_baseline_csv_from_json.py" --in-json "$json" --out-csv "$csv"
}

progress "export metrics CSVs"
export_csv holefill_lite "$HOLEFILL_JSON" "${METRICS}/06_holefill_lite_val565.csv"
export_csv ft_density_finetune "$FT_JSON" "${METRICS}/06b_ft_density_finetune_val565.csv"
export_csv line_b_holefill "$LINEB_JSON" "${METRICS}/07_line_b_holefill_first_val565.csv"

# Keep legacy CSVs if present
[[ -f "${METRICS}/01_superpc_blend_cg_kitti360_vx3.0_val565.csv" ]] || \
  export_csv superpc "$SUPERPC_JSON" "${METRICS}/01_superpc_blend_cg_kitti360_vx3.0_val565.csv" || true
[[ -f "${METRICS}/03_pdlts_density_global_snap_no_vh_tune_val565.csv" ]] || true

progress "gate snapshot holefill_lite"
"$PY" <<PY
import json, sys
sys.path.insert(0, "${SCRIPT_DIR}")
from enh_refine_config import resolve_preset
cfg = resolve_preset("holefill_lite_fill0.25_max10pct_adaptive_post25")
d = cfg.to_dict()
gate = {
    "production_config": d,
    "best_config": d,
    "preset_name": cfg.name,
    "val565_chamfer_mm_holefill_lite": 15.1277,
    "val565_chamfer_mm_ft_density": 14.8831,
    "geometry_primary_note": "PD-LTS UVG finetune light ckpt infer cache",
    "geometry_secondary_note": "SuperPC kitti360 blend_cg submission_candidate",
    "processing_track": "Enhancement Only hybrid",
}
out = "${DELIVERY_DOCS}/gate_snapshots/holefill_lite_gate_decision.json"
json.dump(gate, open(out, "w"), indent=2)
print("wrote", out)
PY

progress "summary.json"
GC2026_ROOT="$GC2026_ROOT" "$PY" <<'PY'
import csv, json, os
from collections import defaultdict

GC = os.environ["GC2026_ROOT"]
metrics_dir = os.path.join(GC, "docs/meeting_delivery/metrics")
models = [
    ("ft_density_finetune", "06b_ft_density_finetune_val565.csv", "primary baseline"),
    ("holefill_lite", "06_holefill_lite_val565.csv", "current submission candidate"),
    ("line_b_holefill", "07_line_b_holefill_first_val565.csv", "ablation"),
    ("superpc_blend_cg", "01_superpc_blend_cg_kitti360_vx3.0_val565.csv", "legacy"),
    ("pdlts_density_frozen", "03_pdlts_density_global_snap_no_vh_tune_val565.csv", "frozen PD-LTS"),
]
out = {
    "updated": "holefill_lite_delivery",
    "submission_preset": "holefill_lite_fill0.25_max10pct_adaptive_post25",
    "models": [],
    "val_sequences": ["TrumanShow", "VictoryHeart", "VirtualLife"],
}
for name, fn, note in models:
    full = os.path.join(metrics_dir, fn)
    if not os.path.isfile(full):
        continue
    rows = list(csv.DictReader(open(full)))
    chamfers = [float(r["chamfer_distance"]) for r in rows]
    by_seq = defaultdict(list)
    for r in rows:
        by_seq[r.get("sequence", "")].append(float(r["chamfer_distance"]))
    out["models"].append({
        "name": name,
        "note": note,
        "csv": f"docs/meeting_delivery/metrics/{fn}",
        "num_frames": len(rows),
        "mean_chamfer_distance": sum(chamfers) / len(chamfers) if chamfers else None,
        "per_sequence_mean_chamfer": {k: sum(v) / len(v) for k, v in sorted(by_seq.items()) if k},
    })
json.dump(out, open(os.path.join(metrics_dir, "summary.json"), "w"), indent=2)
print(json.dumps(out, indent=2))
PY

progress "merge xlsx"
"$PY" "${SCRIPT_DIR}/merge_val565_metrics_xlsx.py"

progress "build submission package"
bash "${SCRIPT_DIR}/build_holefill_lite_submission.sh"

progress "publish candidate symlink"
bash "${SCRIPT_DIR}/publish_holefill_lite_candidate.sh"

progress "meeting figures"
bash "${SCRIPT_DIR}/run_meeting_figures_holefill_lite.sh"

progress "pack tar"
tar -czf "${GC2026_ROOT}/output/GC2026_submission_EnhancementOnly_holefill_lite.tar.gz" \
  -C "${GC2026_ROOT}/submissions" GC2026_Team_EnhancementOnly
cp -f "${GC2026_ROOT}/output/GC2026_submission_EnhancementOnly_holefill_lite.tar.gz" \
  "${DELIVERY_OUT}/submission/" 2>/dev/null || mkdir -p "${DELIVERY_OUT}/submission" && \
  cp -f "${GC2026_ROOT}/output/GC2026_submission_EnhancementOnly_holefill_lite.tar.gz" \
  "${DELIVERY_OUT}/submission/"

progress "sync mirror"
rsync -a --delete --exclude='prepare.log' --exclude='prepare_holefill_lite.log' \
  "${DELIVERY_DOCS}/" "${DELIVERY_OUT}/"
cp -f "$LOG" "${DELIVERY_OUT}/prepare_holefill_lite.log"

echo "[delivery-lite] DONE $(date -Is)"
