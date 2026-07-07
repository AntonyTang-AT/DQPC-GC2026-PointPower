# Submission variant: **B (minimal / lazy imports)**

Smaller `src/` footprint: temporal modules are **not** bundled; imports are deferred until a non-default temporal preset is used.

Production inference (`holefill_adaptive_frame_gate_v2`) does **not** require temporal code paths.

`evaluate_gc_baseline_metrics.py` inlines `enh_path_from_cg()` instead of shipping `evaluate_uvg.py`.

See `../SUBMISSION_VARIANTS.md` for comparison with variant A.
