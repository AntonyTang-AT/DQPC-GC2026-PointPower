# GC2026 UVG-CWI-DQPC Status

Generated: 2026-06-21T08:27:59.944325Z

## Processing Tracks

| Track | Role | Val improve (n=20k) |
|-------|------|---------------------|
| Full Pipeline (primary) | RGBD→CG→SuperPC | pending |
| Enhancement Only (fallback) | Official CG→SuperPC | n/a |

## Enhancement Metrics (val)

- Chamfer improve (n=20k): n/a
- Color PSNR-Y: 63.52832913126947
- Temporal adjacent CD-L1: 15.415282050768534
- ENH frames: 2155

## RGBD Download (val sequences)

```
TicTacToe/RGBD: disk=0.00 GB [MISSING]
VictoryHeart/RGBD: disk=0.00 GB [MISSING]
Incomplete: TicTacToe_UVG-CWI-DQPC_v1-0_RGBD.zip, VictoryHeart_UVG-CWI-DQPC_v1-0_RGBD.zip
```

## Background Chain

- Stage: unknown / not started
- Logs: `output/wait_rgbd_val.log`, `output/full_pipeline_chain.log`
- aria2 tail: `n/a`

## Submission Artifacts

| Artifact | Path | Status |
|----------|------|--------|
| Enhancement tar | `output/submission_candidate_submission.tar.gz` | missing |
| Full Pipeline tar | `output/full_pipeline_candidate_submission.tar.gz` | pending |
| Primary manifest | `submissions/GC2026_Team/manifest.json` | Enhancement until Full ready |

RGBD mapped: 2155 missing: 0

## Next Steps

- Run integrity check: bash scripts/check_integrity.sh
- Finish librealsense: bash scripts/install_cwipc.sh
- Generate rgbd_pairs: bash scripts/post_rgbd_install.sh
- Full Pipeline val smoke: bash scripts/run_full_pipeline_val.sh
- Full Pipeline all sequences: bash scripts/run_full_pipeline.sh
