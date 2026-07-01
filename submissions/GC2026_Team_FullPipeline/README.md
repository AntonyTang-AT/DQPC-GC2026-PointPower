# GC2026 Team — Full Pipeline (N0 cwipc + SuperPC)

## Team Name
GC2026 Team

## Team Members
- *(Update before PR)* Member 1 — Affiliation
- *(Update before PR)* Member 2 — Affiliation

## Algorithm Name
N0 cwipc-native Stage1 + SuperPC blend_cg

## Algorithm Description
Intel RealSense RGBD `.bag` → cwipc-native reconstruction (N0 official filter) → consumer-grade CG PLY → SuperPC enhancement.
88 hard frames use official CG fallback at Stage1 when reconstruction fails.

## Processing Track
**Full Pipeline** (input: RGBD `.bag`)

## How to Run

See [SETUP.md](SETUP.md). Requires **librealsense + cwipc** for Stage1 (`bash src/install_cwipc.sh` on supported Linux).

```bash
export GC2026_ROOT=/path/to/workspace
cd submissions/GC2026_Team_FullPipeline
conda activate superpc
bash src/run.sh              # full 2155 frames (GPU + CPU)
# or smoke: bash src/run_official_val_smoke.sh
```

Outputs:
- Recon CG: `$GC2026_ROOT/output/full_pipeline_n0_v2_cg/`
- ENH: `$GC2026_ROOT/output/full_pipeline_n0_v2_candidate/`

Post: `bash src/post_full_pipeline.sh`

## Hardware / Environment
- Stage1: CPU (cwipc, multi-job); Stage2: 2× NVIDIA RTX 5090
- Ubuntu 22.04, Python 3.9 / 3.12 for Stage1 scripts

## Runtime
See `output/full_pipeline_n0_v2_candidate/runtime.log`.

## Selected SuperPC config
See `config/gate_config.json`.

## Official val565 result (local cd_l1, after backfill fix, Jun 2026)
- ENH vs HE mean: **158.7 mm** (Stage1 bottleneck; Enh Only reference: 48.5 mm)
