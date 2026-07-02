# GC2026 Team — Enhancement Only (frame_gate v2 hybrid)

## Team Name
GC2026 Team

## Team Members
*(Update before official PR — name, affiliation)*

## Algorithm Name
UVG-finetuned PD-LTS light + frame-level SuperPC fill gate v2 (`holefill_adaptive_frame_gate_v2`)

## Algorithm Description
Official CG PLY (v2) → **PD-LTS light UVG finetune** (primary) → **always** snap 1 mm + fill 0.6 density on primary → **per-frame gate** decides SuperPC `blend_cg` hole fill (TrumanShow adaptive; VictoryHeart/VirtualLife skip SuperPC). KNN color from CG.

## Processing Track
**Enhancement Only**

## How to Run

```bash
export GC2026_ROOT=/path/to/workspace
cd submissions/GC2026_Team_EnhancementOnly
conda activate superpc
bash src/run.sh
```

Output: `$GC2026_ROOT/output/submission_candidate_frame_gate_v2/` (2155 ENH PLY).

Smoke: `bash src/run_smoke.sh`

## Local validation (gc_baseline val565, 564 frames)
| Method | Chamfer (mm) |
|--------|-------------|
| ft PD-LTS + density (no SuperPC) | **14.883** |
| **frame_gate v2 (this package)** | **14.870** |
| CG baseline | 17.552 |

See `config/gate_decision.json` for full refine preset.

## Hardware
NVIDIA GPU with CUDA (tested: RTX 5090, 32GB VRAM). Dual-GPU optional via `NUM_GPUS`.

## Runtime
~48 s/frame PD-LTS + SuperPC + refine (RTX 5090). Full 2155 frames: see `runtime.log` after `post_submission_candidate.sh`.
