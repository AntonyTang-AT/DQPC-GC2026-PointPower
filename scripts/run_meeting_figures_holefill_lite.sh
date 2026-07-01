#!/usr/bin/env bash
# Meeting figures for holefill lite delivery (standard charts + hybrid comparison PNGs).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT_DIR:-$ROOT/docs/meeting_delivery/figures}"
FUSION_FIG="${ROOT}/output/ft_val565_fusion/figures"

source /root/miniconda3/etc/profile.d/conda.sh
conda activate superpc
export PYTHONPATH="$ROOT/scripts:${PYTHONPATH:-}"
mkdir -p "$OUT"

echo "[figures-lite] standard meeting figures..."
bash "$ROOT/scripts/run_meeting_figures.sh" || true

echo "[figures-lite] copy hybrid comparison PNGs..."
copy_pair() {
  local s="$1" d="$2"
  if [[ -f "${FUSION_FIG}/${s}" ]]; then
    cp -f "${FUSION_FIG}/${s}" "${OUT}/${d}"
    echo "  copied $d"
  fi
}
copy_pair "model_he_gap_zoom_TrumanShow_TrumanShow_UVG-CWI-DQPC_CG_15_0_170_0072.png" "08_holefill_lite_vs_ft_ts0072.png"
copy_pair "model_he_gap_zoom_VictoryHeart_VictoryHeart_UVG-CWI-DQPC_CG_15_0_196_0041.png" "08b_holefill_lite_vs_ft_vh0041.png"
copy_pair "ft_vs_fusion_gap_VictoryHeart_VictoryHeart_UVG-CWI-DQPC_ENH_15_0_196_0041.png" "09_fusion_gap_vh0041.png"

python3 <<PY
import json, os, time
from pathlib import Path
out = Path("$OUT")
meta_path = out / "meta.json"
meta = {}
if meta_path.is_file():
    meta = json.loads(meta_path.read_text())
meta["holefill_lite_delivery"] = {
    "updated": time.strftime("%Y-%m-%d"),
    "submission_preset": "holefill_lite_fill0.25_max10pct_adaptive_post25",
    "val565_chamfer_mm": {"ft_density": 14.883, "holefill_lite": 15.128},
    "extra_figures": [
        "08_holefill_lite_vs_ft_ts0072.png",
        "08b_holefill_lite_vs_ft_vh0041.png",
        "09_fusion_gap_vh0041.png",
    ],
}
meta_path.write_text(json.dumps(meta, indent=2))
print("updated meta.json")
PY

MIRROR="$ROOT/output/meeting_delivery/figures"
mkdir -p "$MIRROR"
rsync -a "$OUT/" "$MIRROR/"
echo "[figures-lite] done -> $OUT"
