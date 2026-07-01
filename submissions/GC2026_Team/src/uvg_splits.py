#!/usr/bin/env python3
"""Official UVG-CWI-DQPC GC2026 dataset splits (Grand Challenge rules §3.2)."""
from __future__ import annotations

# Train: 9 sequences (TicTacToe is train, not val).
OFFICIAL_TRAIN_SEQUENCES = (
    "BlueSpeech",
    "BlueVolley",
    "BouncingBlue",
    "FitFluencer",
    "GoodVision",
    "Mannequin",
    "OrangeKettlebell",
    "PinkNoir",
    "TicTacToe",
)

# Validation: 3 sequences (565 frames total).
OFFICIAL_VAL_SEQUENCES = (
    "TrumanShow",
    "VictoryHeart",
    "VirtualLife",
)

# Legacy local dev split (362 frames) — do not use for official reporting.
LEGACY_VAL362_SEQUENCES = (
    "TicTacToe",
    "VictoryHeart",
)

ALL_SEQUENCES = OFFICIAL_TRAIN_SEQUENCES + OFFICIAL_VAL_SEQUENCES


def sequence_from_path(path: str) -> str:
    if "/UVG-CWI-DQPC/" not in path:
        raise ValueError(f"Not a UVG path: {path}")
    return path.split("/UVG-CWI-DQPC/")[1].split("/")[0]


def filter_pairs_by_sequences(pairs_file: str, sequences: set[str]) -> list[str]:
    lines: list[str] = []
    with open(pairs_file, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip():
                continue
            cg = line.split()[0]
            if sequence_from_path(cg) in sequences:
                lines.append(line)
    return lines
