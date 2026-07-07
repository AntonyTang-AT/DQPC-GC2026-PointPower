# GC2026 Enhancement Only — submission variants

**Official channel:** fork [UVG-CWI/submissions](https://github.com/UVG-CWI/submissions), copy package to `submissions/PointPower/`, open a PR. See `GC2026_Team_EnhancementOnly/SETUP.md` § Official submission channel.

| Directory | Description | Submit? |
|-----------|-------------|---------|
| `GC2026_Team_EnhancementOnly_original` | Snapshot **before** A/B fixes (missing temporal imports; do not use) | No |
| `GC2026_Team_EnhancementOnly_A` | **Variant A** — full dependency copy (recommended) | **Yes** |
| `GC2026_Team_EnhancementOnly_B` | **Variant B** — minimal package, lazy temporal imports | Optional |
| `GC2026_Team_EnhancementOnly` | Active package (PointPower docs, same code as A) | **Yes** |

## Variant A vs B

| | A (full) | B (minimal) |
|---|----------|-------------|
| `enh_temporal*.py` | Included | Not included |
| `evaluate_uvg.py` | Included | Inlined in eval script |
| Production `run.sh` | Works | Works |
| Temporal presets | Works if modules present | Needs extra files from main repo |
| Package size (src) | Larger | Smaller |

## Archives

After packaging:

- `GC2026_Team_EnhancementOnly.tar.gz` — **submit this** (same as A)
- `GC2026_Team_EnhancementOnly_A.tar.gz` — variant A archive
- `GC2026_Team_EnhancementOnly_B.tar.gz` — variant B archive (minimal)

**Smoke verified (2 frames):** PD-LTS → SuperPC → frame_gate v2 refine, 2026-07-04.
