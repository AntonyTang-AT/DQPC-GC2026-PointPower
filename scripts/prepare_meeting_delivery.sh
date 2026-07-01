#!/usr/bin/env bash
# Rebuild docs/meeting_delivery: five canonical models + merged report + figures.
set -euo pipefail

GC2026_ROOT="${GC2026_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT_DIR="${GC2026_ROOT}/scripts"
DOCS="${GC2026_ROOT}/docs/meeting_delivery"
METRICS="${DOCS}/metrics"
FIGURES="${DOCS}/figures"
CONFIG="${DOCS}/config"
OUT="${GC2026_ROOT}/output/meeting_delivery"
PY="${PY:-python3}"
LOG="${OUT}/prepare.log"

mkdir -p "$METRICS" "$FIGURES" "$CONFIG" "$OUT/submission"
exec > >(tee -a "$LOG") 2>&1
echo "[delivery] START $(date -Is)"

progress() { echo "[delivery] $* $(date +%H:%M:%S)"; }

# --- source eval JSONs (best per category) ---
JSON_SUPERPC_RECORD="${DOCS}/metrics/.superpc_filter_snap1_record.json"
JSON_PDLTS_FROZEN="${GC2026_ROOT}/output/enh_refine_val565_selection/vh_snap0/evaluation_gc_baseline_val565.json"
JSON_PDLTS_FT="${GC2026_ROOT}/output/pdlts_finetune_uvg/val565_refine/pdlts_light_snap1_fill0.6_density/evaluation_gc_baseline_val565.json"
JSON_FUSION_FROZEN="${GC2026_ROOT}/output/enh_refine_val565_selection/region_hybrid_pdlts_superpc_snap1_fill0.6_density/evaluation_gc_baseline_val565.json"
JSON_FUSION_FT="${GC2026_ROOT}/output/ft_val565_fusion/holefill_adaptive_frame_gate_v2/evaluation_gc_baseline_val565.json"

export_csv() {
  local json="$1" csv="$2"
  [[ -f "$json" ]] || { echo "missing $json" >&2; exit 1; }
  "$PY" "${SCRIPT_DIR}/export_gc_baseline_csv_from_json.py" --in-json "$json" --out-csv "$csv"
}

progress "export five model CSVs"
export_csv "$JSON_PDLTS_FROZEN" "${METRICS}/02_pdlts_frozen_best_val565.csv"
export_csv "$JSON_PDLTS_FT" "${METRICS}/03_pdlts_finetune_best_val565.csv"
export_csv "$JSON_FUSION_FROZEN" "${METRICS}/04_fusion_frozen_pdlts_best_val565.csv"
export_csv "$JSON_FUSION_FT" "${METRICS}/05_fusion_finetune_pdlts_best_val565.csv"

# SuperPC best: per-sequence aggregate (per-frame PLY deleted in Phase2)
"$PY" <<'PY'
import json, csv, os
GC = os.environ.get("GC2026_ROOT", "/root/autodl-tmp/GC2026")
rec_path = f"{GC}/docs/meeting_delivery/config/superpc_phase2_record.json"
if not os.path.isfile(rec_path):
    rec_path = f"{GC}/output/meeting_delivery/metrics/superpc_filter_snap1.0_phase2_record.json"
pref_path = f"{GC}/output/enh_refine_phase2/per_sequence_model_preference.json"
out = f"{GC}/docs/meeting_delivery/metrics/01_superpc_best_val565.csv"
rec = json.load(open(rec_path))
pref = json.load(open(pref_path)) if os.path.isfile(pref_path) else {"sequences": []}
rows = []
for r in pref.get("sequences", []):
    cd = r.get("superpc_filter")
    if cd is None:
        continue
    rows.append({
        "granularity": "per_sequence_mean",
        "sequence": r["sequence"],
        "chamfer_distance": cd,
        "note": "SuperPC filter_cg + snap1mm (Phase2 best)",
    })
rows.append({
    "granularity": "val565_aggregate",
    "sequence": "ALL",
    "chamfer_distance": rec["mean_enh_chamfer_distance"],
    "num_frames": rec.get("num_frames_val565", 564),
    "note": "aggregate",
})
with open(out, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=["granularity", "sequence", "chamfer_distance", "num_frames", "note"])
    w.writeheader()
    w.writerows(rows)
print("wrote", out)
PY
export GC2026_ROOT="$GC2026_ROOT"

progress "models_registry.json + summary.json"
"$PY" <<PY
import csv, json, os
from collections import defaultdict

GC = "$GC2026_ROOT"
metrics = os.path.join(GC, "docs/meeting_delivery/metrics")

def stats_from_csv(path):
    rows = list(csv.DictReader(open(path)))
    if not rows:
        return None
    if "granularity" in rows[0]:
        agg = [r for r in rows if r.get("granularity") == "val565_aggregate"]
        if agg:
            return {"mean": float(agg[0]["chamfer_distance"]), "n": int(agg[0].get("num_frames") or 564), "per_seq": {}}
        return None
    chamfers = [float(r["chamfer_distance"]) for r in rows]
    by = defaultdict(list)
    for r in rows:
        by[r.get("sequence", "")].append(float(r["chamfer_distance"]))
    return {
        "mean": sum(chamfers) / len(chamfers),
        "n": len(chamfers),
        "per_seq": {k: sum(v) / len(v) for k, v in sorted(by.items()) if k},
    }

cats = [
    {
        "id": "superpc_only",
        "label": "仅 SuperPC（含后处理）",
        "preset": "SuperPC kitti360 filter_cg + snap 1 mm",
        "csv": "metrics/01_superpc_best_val565.csv",
        "eval_json": "Phase2 record (per-frame PLY deleted)",
        "geometry": "superpc_blend_cg secondary only",
        "role": "研发线最优；仍劣于 CG",
    },
    {
        "id": "pdlts_frozen_only",
        "label": "仅 PD-LTS 未 fine-tune（含后处理）",
        "preset": "vh_snap0 (density base + VictoryHeart snap=0)",
        "csv": "metrics/02_pdlts_frozen_best_val565.csv",
        "eval_json": "output/enh_refine_val565_selection/vh_snap0/evaluation_gc_baseline_val565.json",
        "geometry": "frozen Denoiseflow-light-FBM",
        "role": "val565 冻结权重最优；全局统一配置 density=17.504 mm",
        "alt_preset": "pdlts_light_snap1_fill0.6_density (global uniform, 17.504 mm)",
    },
    {
        "id": "pdlts_finetune_only",
        "label": "仅 PD-LTS 已 fine-tune（含后处理）",
        "preset": "pdlts_light_snap1_fill0.6_density (UVG finetune ckpt)",
        "csv": "metrics/03_pdlts_finetune_best_val565.csv",
        "eval_json": "output/pdlts_finetune_uvg/val565_refine/pdlts_light_snap1_fill0.6_density/evaluation_gc_baseline_val565.json",
        "geometry": "DenoiseFlow-light-UVG-finetune",
        "role": "无 SuperPC 融合基线",
    },
    {
        "id": "fusion_frozen_pdlts",
        "label": "未 fine-tune PD-LTS 最佳融合",
        "preset": "region_hybrid_pdlts_superpc_snap1_fill0.6_density",
        "csv": "metrics/04_fusion_frozen_pdlts_best_val565.csv",
        "eval_json": "output/enh_refine_val565_selection/region_hybrid_pdlts_superpc_snap1_fill0.6_density/evaluation_gc_baseline_val565.json",
        "geometry": "frozen PD-LTS primary + SuperPC blend_cg region fill",
        "role": "冻结权重 hybrid 最优",
    },
    {
        "id": "fusion_finetune_pdlts",
        "label": "已 fine-tune PD-LTS 最佳融合（提交）",
        "preset": "holefill_adaptive_frame_gate_v2",
        "csv": "metrics/05_fusion_finetune_pdlts_best_val565.csv",
        "eval_json": "output/ft_val565_fusion/holefill_adaptive_frame_gate_v2/evaluation_gc_baseline_val565.json",
        "geometry": "ft PD-LTS + always density + frame SuperPC gate",
        "role": "当前 Enhancement Only 提交候选",
    },
]

for c in cats:
    st = stats_from_csv(os.path.join(GC, "docs/meeting_delivery", c["csv"]))
    if st:
        c["mean_chamfer_mm"] = st["mean"]
        c["num_frames"] = st["n"]
        c["per_sequence_mean_chamfer"] = st["per_seq"]
    # superpc: per-seq from aggregate CSV
    if c["id"] == "superpc_only" and not c.get("per_sequence_mean_chamfer"):
        rows = list(csv.DictReader(open(os.path.join(GC, "docs/meeting_delivery", c["csv"]))))
        c["per_sequence_mean_chamfer"] = {
            r["sequence"]: float(r["chamfer_distance"])
            for r in rows
            if r.get("granularity") == "per_sequence_mean" and r.get("sequence")
        }

registry = {
    "updated": "five_models_delivery",
    "submission_preset": "holefill_adaptive_frame_gate_v2",
    "metric": "chamfer_distance = (accuracy + completeness) / 2",
    "eval_set": "val565 (564 frames)",
    "categories": cats,
}
json.dump(registry, open(os.path.join(metrics, "models_registry.json"), "w"), indent=2)

summary = {
    "updated": registry["updated"],
    "submission": cats[-1]["id"],
    "models": [
        {
            "name": c["id"],
            "label": c["label"],
            "preset": c["preset"],
            "csv": f"docs/meeting_delivery/{c['csv']}",
            "mean_chamfer_distance": c.get("mean_chamfer_mm"),
            "num_frames": c.get("num_frames"),
            "per_sequence_mean_chamfer": c.get("per_sequence_mean_chamfer"),
        }
        for c in cats
    ],
}
json.dump(summary, open(os.path.join(metrics, "summary.json"), "w"), indent=2)
print(json.dumps(summary, indent=2))
PY

progress "submission gate snapshot"
mkdir -p "${CONFIG}"
[[ -f "${GC2026_ROOT}/docs/meeting_delivery/metrics/superpc_filter_snap1.0_phase2_record.json" ]] && \
  cp -f "${GC2026_ROOT}/docs/meeting_delivery/metrics/superpc_filter_snap1.0_phase2_record.json" \
  "${CONFIG}/superpc_phase2_record.json" 2>/dev/null || \
  cp -f "${GC2026_ROOT}/output/meeting_delivery/metrics/superpc_filter_snap1.0_phase2_record.json" \
  "${CONFIG}/superpc_phase2_record.json" 2>/dev/null || true
"$PY" <<PY
import json, sys
sys.path.insert(0, "${SCRIPT_DIR}")
from enh_refine_config import resolve_preset
cfg = resolve_preset("holefill_adaptive_frame_gate_v2")
d = cfg.to_dict()
json.dump({
    "preset_name": cfg.name,
    "production_config": d,
    "val565_chamfer_mm": 14.8699,
}, open("${CONFIG}/submission_gate.json", "w"), indent=2)
PY

progress "merge xlsx"
"$PY" "${SCRIPT_DIR}/merge_val565_five_models_xlsx.py"

progress "build submission package"
bash "${SCRIPT_DIR}/build_frame_gate_v2_submission.sh"

progress "figures"
bash "${SCRIPT_DIR}/run_meeting_delivery_figures.sh"

progress "pack tar"
tar -czf "${GC2026_ROOT}/output/GC2026_submission_EnhancementOnly_frame_gate_v2.tar.gz" \
  -C "${GC2026_ROOT}/submissions" GC2026_Team_EnhancementOnly
cp -f "${GC2026_ROOT}/output/GC2026_submission_EnhancementOnly_frame_gate_v2.tar.gz" "${OUT}/submission/"

progress "prune old files"
rm -rf "${DOCS}/gate_snapshots" "${DOCS}/.ipynb_checkpoints" "${DOCS}/figures/.ipynb_checkpoints"
rm -f "${DOCS}"/PROJECT_STRATEGY_REPORT.md "${DOCS}"/VAL565_METRICS_XLSX.md \
  "${DOCS}"/MODEL_MODIFICATION_REPORT.md "${DOCS}"/METHOD_VS_PD_LTS.md \
  "${DOCS}"/METHOD_VS_SUPERPC.md "${DOCS}"/FRAME_GATE_V2_RESULTS.md \
  "${DOCS}"/FUSION_ROOT_CAUSE_DIAGNOSIS.md "${DOCS}"/HOLEFILL_LITE_GAP_VS_FT.md \
  "${DOCS}"/SUPERPC_VAL565_RECORD.md "${DOCS}"/SUBMISSION_COMPLIANCE.md \
  "${DOCS}"/val565_gc_baseline_metrics.xlsx
# legacy numbered CSVs (pre five-model layout)
rm -f "${METRICS}"/02_pdlts_vh_snap0_val565.csv "${METRICS}"/03_pdlts_density_global_snap_no_vh_tune_val565.csv \
  "${METRICS}"/04_pdlts_raw_val565.csv "${METRICS}"/05_superpc_filter_snap1.0_val565.csv \
  "${METRICS}"/06_holefill_lite_val565.csv "${METRICS}"/06b_ft_density_finetune_val565.csv \
  "${METRICS}"/07_line_b_holefill_first_val565.csv "${METRICS}"/08_frame_gate_v2_val565.csv \
  "${METRICS}"/01_superpc_blend_cg_kitti360_vx3.0_val565.csv \
  "${METRICS}"/superpc_filter_snap1.0_phase2_record.json
# keep only essential figures
cd "${FIGURES}" && rm -f \
  01_overview_qualitative.png 02_dual_reference.png 03_zoom_cg_fidelity.png \
  04_chart_per_sequence.png 05_chart_acc_comp.png 06_chart_frame_diff.png \
  07_diagram_pipeline.png 08_holefill_lite_vs_ft_ts0072.png 08b_holefill_lite_vs_ft_vh0041.png \
  09_fusion_gap_vh0041.png bar_accuracy_completeness.png meta.json \
  ft_vs_fusion_gap_*.png model_he_gap_zoom_*.png 08_frame_gate_v2_vs_ft_*.png 08b_frame_gate_v2_vs_ft_*.png \
  figures_manifest.json README.md 2>/dev/null || true
cp -f bar_per_sequence_chamfer.png bar_val565_five_models.png 2>/dev/null || true

progress "sync mirror"
rsync -a --delete --exclude='prepare.log' "${DOCS}/" "${OUT}/"

echo "[delivery] DONE $(date -Is)"
