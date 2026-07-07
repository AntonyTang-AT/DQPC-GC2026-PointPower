#!/usr/bin/env bash
# Generate CG/HE pair lists for UVG-CWI-DQPC (inference + PD-LTS fine-tune).
#
# Usage:
#   export GC2026_ROOT=/workspace
#   bash data/generate_pair_lists.sh
#
# Creates under $GC2026_ROOT/data/processed/:
#   all_cg_only_cgv2.txt              — all CG frames (2155)
#   all_pairs_cgv2.txt                — all CG/HE pairs (where HE exists)
#   train_cg_only_official_cgv2.txt   — train split CG only (9 seq, 1590)
#   train_pairs_official_cgv2.txt     — train split CG/HE pairs (fine-tune)
#   val_cg_only_official_cgv2.txt     — val565 CG only (564)
#   val_pairs_official_cgv2.txt       — val565 CG/HE pairs (evaluation)
#
# Data layout (relative to $GC2026_ROOT):
#   data/raw/UVG-CWI-DQPC/<Sequence>/consumer-grade_capture_system/CG/15fps/
#   data/raw/UVG-CWI-DQPC/<TrainSeq>/high-end_capture_system/HE/15fps/  (training)
# See data/DATA_LAYOUT.md
set -euo pipefail
GC2026_ROOT="${GC2026_ROOT:-./workspace}"
RAW="${GC2026_ROOT}/data/raw/UVG-CWI-DQPC"
OUT="${GC2026_ROOT}/data/processed"
mkdir -p "$OUT"

# Official GC2026 split (Grand Challenge rules §3.2)
TRAIN_SEQS=(BlueSpeech BlueVolley BouncingBlue FitFluencer GoodVision Mannequin \
            OrangeKettlebell PinkNoir TicTacToe)
VAL_SEQS=(TrumanShow VictoryHeart VirtualLife)
ALL_SEQS=("${TRAIN_SEQS[@]}" "${VAL_SEQS[@]}")

echo "[generate_pair_lists] GC2026_ROOT=$GC2026_ROOT"

write_cg_list() {
  local outfile="$1"
  shift
  local seqs=("$@")
  : > "$outfile"
  for seq in "${seqs[@]}"; do
    find "$RAW/$seq/consumer-grade_capture_system/CG/15fps" -name '*.ply' 2>/dev/null | sort >> "$outfile"
  done
}

write_pairs_list() {
  local outfile="$1"
  shift
  local seqs=("$@")
  : > "$outfile"
  local cg_ply he_ply basename he_name missing=0
  for seq in "${seqs[@]}"; do
    while IFS= read -r cg_ply; do
      [[ -n "$cg_ply" ]] || continue
      basename=$(basename "$cg_ply")
      he_name="${basename/CG/HE}"
      he_ply="$RAW/$seq/high-end_capture_system/HE/15fps/$he_name"
      if [[ -f "$he_ply" ]]; then
        printf '%s\t%s\n' "$cg_ply" "$he_ply" >> "$outfile"
      else
        echo "[generate_pair_lists] WARN: missing HE for $cg_ply" >&2
        missing=$((missing + 1))
      fi
    done < <(find "$RAW/$seq/consumer-grade_capture_system/CG/15fps" -name '*.ply' 2>/dev/null | sort)
  done
  if [[ "$missing" -gt 0 ]]; then
    echo "[generate_pair_lists] WARN: $missing CG frames without matching HE (training/eval may be incomplete)" >&2
  fi
}

ALL_CG="$OUT/all_cg_only_cgv2.txt"
ALL_PAIRS="$OUT/all_pairs_cgv2.txt"
TRAIN_CG="$OUT/train_cg_only_official_cgv2.txt"
TRAIN_PAIRS="$OUT/train_pairs_official_cgv2.txt"
VAL_CG="$OUT/val_cg_only_official_cgv2.txt"
VAL_PAIRS="$OUT/val_pairs_official_cgv2.txt"

write_cg_list "$ALL_CG" "${ALL_SEQS[@]}"
write_pairs_list "$ALL_PAIRS" "${ALL_SEQS[@]}"
write_cg_list "$TRAIN_CG" "${TRAIN_SEQS[@]}"
write_pairs_list "$TRAIN_PAIRS" "${TRAIN_SEQS[@]}"
write_cg_list "$VAL_CG" "${VAL_SEQS[@]}"
write_pairs_list "$VAL_PAIRS" "${VAL_SEQS[@]}"

echo "[generate_pair_lists] $(wc -l < "$ALL_CG") all CG      -> $ALL_CG"
echo "[generate_pair_lists] $(wc -l < "$ALL_PAIRS") all pairs  -> $ALL_PAIRS"
echo "[generate_pair_lists] $(wc -l < "$TRAIN_CG") train CG    -> $TRAIN_CG"
echo "[generate_pair_lists] $(wc -l < "$TRAIN_PAIRS") train pairs -> $TRAIN_PAIRS"
echo "[generate_pair_lists] $(wc -l < "$VAL_CG") val CG       -> $VAL_CG"
echo "[generate_pair_lists] $(wc -l < "$VAL_PAIRS") val pairs   -> $VAL_PAIRS"
echo "[generate_pair_lists] DONE"
