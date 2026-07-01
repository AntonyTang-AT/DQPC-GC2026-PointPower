#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT_DIR:-$ROOT/docs/meeting_delivery/figures}"
FUSION_FIG="${ROOT}/output/ft_val565_fusion/figures"

source /root/miniconda3/etc/profile.d/conda.sh
conda activate superpc
export PYTHONPATH="$ROOT/scripts:${PYTHONPATH:-}"
mkdir -p "$OUT" "$FUSION_FIG"

echo "[figures] bar + pipeline (five models)..."
python3 <<PY
import argparse
from pathlib import Path
import sys
sys.path.insert(0, "$ROOT/scripts")
from render_val565_paper_figures import fig_bar_per_seq, fig_pipeline

out = Path("$OUT")
args = argparse.Namespace(dpi=200, vmax_mm=50.0, elev=18.0, azim=-68.0, max_points=100000)
fig_bar_per_seq(out, args)
fig_pipeline(out, args)
cp = out / "bar_per_sequence_chamfer.png"
if cp.is_file():
    (out / "bar_val565_five_models.png").write_bytes(cp.read_bytes())
print("bar + pipeline done")
PY

echo "[figures] gap comparison..."
python3 "$ROOT/scripts/render_model_he_gap_comparison.py" \
  --sequence TrumanShow \
  --cg-name TrumanShow_UVG-CWI-DQPC_CG_15_0_170_0072.ply \
  --out-dir "$FUSION_FIG"
python3 "$ROOT/scripts/render_model_he_gap_comparison.py" \
  --sequence VictoryHeart \
  --cg-name VictoryHeart_UVG-CWI-DQPC_CG_15_0_196_0041.ply \
  --out-dir "$FUSION_FIG"

cp -f "${FUSION_FIG}/model_he_gap_zoom_TrumanShow_TrumanShow_UVG-CWI-DQPC_CG_15_0_170_0072.png" \
  "${OUT}/compare_ts0072.png"
cp -f "${FUSION_FIG}/model_he_gap_zoom_VictoryHeart_VictoryHeart_UVG-CWI-DQPC_CG_15_0_196_0041.png" \
  "${OUT}/compare_vh0041.png"

# keep only essential figures
cd "$OUT" && rm -f \
  01_overview_qualitative.png 02_dual_reference.png 03_zoom_cg_fidelity.png \
  04_chart_per_sequence.png 05_chart_acc_comp.png 06_chart_frame_diff.png \
  07_diagram_pipeline.png 08_holefill_lite_vs_ft_ts0072.png 08b_holefill_lite_vs_ft_vh0041.png \
  09_fusion_gap_vh0041.png bar_accuracy_completeness.png meta.json \
  ft_vs_fusion_gap_*.png model_he_gap_zoom_*.png 08_frame_gate_v2_vs_ft_*.png 08b_frame_gate_v2_vs_ft_*.png \
  figures_manifest.json README.md 2>/dev/null || true

rsync -a "$OUT/" "$ROOT/output/meeting_delivery/figures/"
echo "[figures] done -> $OUT"
