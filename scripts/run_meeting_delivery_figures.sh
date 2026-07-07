#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT_DIR:-$ROOT/docs/meeting_delivery/figures}"

source /root/miniconda3/etc/profile.d/conda.sh
conda activate superpc
export PYTHONPATH="$ROOT/scripts:${PYTHONPATH:-}"
mkdir -p "$OUT"

echo "[figures] bar + pipeline..."
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
PY

echo "[figures] model framework diagram..."
python3 "$ROOT/scripts/render_model_framework_diagram.py" --out-dir "$OUT"

echo "[figures] three-model point cloud comparisons (sheet3/4/7)..."
python3 "$ROOT/scripts/render_three_models_comparison.py" --out-dir "$OUT"

# keep delivery set lean
cd "$OUT"
rm -f meta.json figures_manifest.json README.md \
  model_he_gap_zoom_*.png compare_ts0072.png compare_vh0041.png \
  compare3_lr_*.png compare3_lr_*.json \
  08_*.png 09_*.png 0[1-7]_*.png bar_accuracy_completeness.png compare5_*.png compare5_*.json 2>/dev/null || true

rsync -a "$OUT/" "$ROOT/output/meeting_delivery/figures/"
echo "[figures] done -> $OUT ($(ls -1 compare3_*.png 2>/dev/null | wc -l) compare3 images)"
