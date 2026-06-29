# GC2026 Team — Enhancement Only (PD-LTS + density refine)

## Team Name
GC2026 Team

## Team Members
- *(Update before PR)* Member 1 — Affiliation
- *(Update before PR)* Member 2 — Affiliation

## Algorithm Name
PD-LTS light + snap/fill density_adaptive (`pdlts_light_snap1_fill0.6_density`)

## Algorithm Description
Official consumer-grade CG PLY (v2) → **PD-LTS** light denoising (frozen `Denoiseflow-light-FBM.ckpt`) → geometric refinement: snap to denoised geometry (1.0 mm) + density-adaptive hole fill (0.6 mm base). KNN color transfer from input CG. No fine-tuning on UVG data; no per-sequence snap overrides.

## Processing Track
**Enhancement Only** (input: official CG `.ply` files only; no RGBD `.bag` required)

## How to Run

See [SETUP.md](SETUP.md) for PD-LTS clone, checkpoint, and `setup_pdlts_deps.sh`.

```bash
export GC2026_ROOT=/path/to/workspace
cd submissions/GC2026_Team_EnhancementOnly
conda activate superpc
bash src/run.sh
```

Outputs: `$GC2026_ROOT/output/submission_candidate_pdlts_density/` (2155 ENH PLY).

**Smoke test (2 val frames):** `bash src/run_smoke.sh`

Optional: `bash src/post_submission_candidate.sh` (manifest + val565 gc_baseline eval)

## Hardware / Environment
- NVIDIA GPU recommended (dual-GPU PD-LTS sharding when 2+ GPUs visible)
- Ubuntu 22.04, Python 3.9, PyTorch 2.8+cu128 (RTX 5090 tested)
- Coordinate system: consumer-grade capture coordinates (mm), same as input CG

## Runtime
Stage1 PD-LTS + Stage2 CPU/GPU refine. See `output/submission_candidate/runtime.log` after full run.

## Selected config
See `config/gate_config.json` — preset `pdlts_light_snap1_fill0.6_density`.

## Local validation (gc_baseline aligned, official val565)
- CG baseline chamfer_distance: **17.552 mm**
- This submission ENH (density, global snap=1): **17.504 mm** (564 val frames)
