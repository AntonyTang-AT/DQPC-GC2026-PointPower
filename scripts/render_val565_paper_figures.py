#!/usr/bin/env python3
"""Generate val565 paper / meeting figures (heatmap, ablation, charts, etc.)."""
from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import matplotlib.pyplot as plt
import numpy as np
from matplotlib import cm
from matplotlib.patches import FancyArrowPatch, FancyBboxPatch
from scipy.spatial import cKDTree

SCRIPT_DIR = Path(__file__).resolve().parent
GC2026_ROOT = SCRIPT_DIR.parent
sys.path.insert(0, str(SCRIPT_DIR))

from evaluate_gc_baseline_metrics import apply_transform, load_align_matrix  # noqa: E402
from render_val565_qualitative import (  # noqa: E402
    METRIC_CSVS,
    FramePick,
    choose_zoom_boxes,
    draw_inset,
    draw_panel,
    load_metric_rows,
    mask_box,
    pick_best_frame,
    project_points,
    resolve_ply,
)
from render_val565_error_heatmap import (  # noqa: E402
    HEATMAP_PANELS,
    aligned_point_errors,
    draw_error_inset,
    draw_error_panel,
)
from uvg_io import filter_cg_outliers, read_ply_xyz_rgb  # noqa: E402

FIGURES_DIR = GC2026_ROOT / "docs/meeting_delivery/figures"
METRICS_DIR = GC2026_ROOT / "docs/meeting_delivery/metrics"
SUMMARY_JSON = METRICS_DIR / "summary.json"
CG_BASELINE_CSV = GC2026_ROOT / "ACMMM26_GC_baseline.csv"

METHOD_DIRS_EXTRA = {
    "pdlts_density": "output/enh_refine_p0_p1_p2/pdlts_light_snap1_fill0.6_density",
}

METRIC_CSVS_EXTRA = {
    "pdlts_density": "docs/meeting_delivery/metrics/03_pdlts_density_global_snap_no_vh_tune_val565.csv",
}

VAL_SEQS = ["TrumanShow", "VictoryHeart", "VirtualLife"]

MODEL_LABELS = {
    "cg": "CG baseline",
    "superpc_blend_cg": "SuperPC blend_cg",
    "pdlts_raw": "PD-LTS raw",
    "pdlts_density": "PD-LTS density",
    "pdlts_vh_snap0": "PD-LTS vh_snap0",
}


def resolve_ply_ext(root: Path, panel_key: str, pick: FramePick) -> Path:
    if panel_key in METHOD_DIRS_EXTRA:
        seq = pick.sequence
        return root / METHOD_DIRS_EXTRA[panel_key] / seq / pick.enh_name
    return resolve_ply(root, panel_key, pick)


def load_frame_meta(meta_json: Optional[Path]) -> FramePick:
    if meta_json and meta_json.is_file():
        d = json.loads(meta_json.read_text(encoding="utf-8"))
        if "frame" in d:
            d = d["frame"]
        key = (d["sequence"], d["frame_index_val565"])
        raw = load_metric_rows(METRIC_CSVS["pdlts_raw"])
        density = load_metric_rows(METRIC_CSVS_EXTRA["pdlts_density"])
        vh = load_metric_rows(METRIC_CSVS["pdlts_vh_snap0"])
        sp = load_metric_rows(METRIC_CSVS["superpc_blend_cg"])
        return FramePick(
            sequence=d["sequence"],
            frame_idx=d["frame_index_val565"],
            enh_name=d["enh_filename"],
            cg_name=d["cg_filename"],
            he_name=d["he_filename"],
            chamfer={
                "superpc_blend_cg": float(sp[key]["chamfer_distance"]),
                "pdlts_raw": float(raw[key]["chamfer_distance"]),
                "pdlts_density": float(density[key]["chamfer_distance"]),
                "pdlts_vh_snap0": float(vh[key]["chamfer_distance"]),
            },
            gap_superpc_minus_vh=float(sp[key]["chamfer_distance"]) - float(vh[key]["chamfer_distance"]),
        )
    return pick_best_frame()


def tag_from_pick(pick: FramePick) -> str:
    return f"{pick.sequence}_{pick.frame_idx}_{pick.enh_name.replace('.ply', '')}"


def fig_heatmap(pick: FramePick, out_dir: Path, args) -> Path:
    he_path = (
        GC2026_ROOT / "data/raw/UVG-CWI-DQPC" / pick.sequence
        / "high-end_capture_system/HE/15fps" / pick.he_name
    )
    panel_data: Dict[str, Tuple[np.ndarray, np.ndarray, float]] = {}
    for key, _, _ in HEATMAP_PANELS:
        if key == "he":
            xyz, _ = read_ply_xyz_rgb(str(he_path), max_points=args.max_points)
            panel_data[key] = (xyz, np.zeros(xyz.shape[0], dtype=np.float32), 0.0)
            continue
        ply = resolve_ply_ext(GC2026_ROOT, key, pick)
        xyz, dist, acc, _ = aligned_point_errors(ply, he_path, pick.sequence, args.max_points, 42)
        panel_data[key] = (xyz, dist, acc)

    sp_xyz = panel_data["superpc_blend_cg"][0]
    vh_xyz = panel_data["pdlts_vh_snap0"][0]
    he_xyz = panel_data["he"][0]
    c1, h1, c2, h2 = choose_zoom_boxes(he_xyz, sp_xyz, vh_xyz)
    boxes = [(c1, h1), (c2, h2)]

    fig, axes = plt.subplots(1, len(HEATMAP_PANELS), figsize=(14, 3.6), dpi=args.dpi)
    fig.subplots_adjust(wspace=0.03, left=0.02, right=0.88, top=0.80, bottom=0.08)
    fig.suptitle(
        f"Per-point error to HE (aligned) — {pick.sequence} / {pick.enh_name}",
        fontsize=11,
        y=0.98,
    )
    for ax, (key, title, _) in zip(axes, HEATMAP_PANELS):
        xyz, dist, acc = panel_data[key]
        if key == "he":
            px, py = project_points(xyz, args.elev, args.azim)
            rgb = read_ply_xyz_rgb(str(he_path), max_points=args.max_points)[1]
            ax.scatter(px, py, c=np.clip(rgb, 0, 1), s=0.12, linewidths=0, rasterized=True)
            ax.set_aspect("equal")
            ax.axis("off")
            ax.set_title(title, fontsize=9)
        else:
            cd = pick.chamfer.get(key)
            t = f"{title}\nCD={cd:.2f} mm" if cd else title
            draw_error_panel(ax, xyz, dist, t, args.elev, args.azim, args.vmax_mm, acc, boxes=boxes)
            draw_error_inset(fig, ax, xyz, dist, c1, h1, args.elev, args.azim, args.vmax_mm, "upper left")
            draw_error_inset(fig, ax, xyz, dist, c2, h2, args.elev, args.azim, args.vmax_mm, "lower right")

    cbar_ax = fig.add_axes([0.90, 0.15, 0.015, 0.65])
    sm = cm.ScalarMappable(cmap="turbo", norm=plt.Normalize(0, args.vmax_mm))
    sm.set_array([])
    fig.colorbar(sm, cax=cbar_ax).set_label("distance to HE (mm)", fontsize=9)

    out_png = out_dir / f"error_heatmap_{tag_from_pick(pick)}.png"
    fig.savefig(out_png, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    meta = {
        "figure": "error_heatmap",
        "sequence": pick.sequence,
        "frame_index_val565": pick.frame_idx,
        "per_panel_accuracy_mm": {k: panel_data[k][2] for k, _, _ in HEATMAP_PANELS if k != "he"},
        "chamfer_from_csv": pick.chamfer,
        "vmax_mm": args.vmax_mm,
    }
    (out_dir / f"error_heatmap_{tag_from_pick(pick)}.json").write_text(
        json.dumps(meta, indent=2), encoding="utf-8",
    )
    return out_png


def fig_ablation(pick: FramePick, out_dir: Path, args) -> Path:
    panels = [
        ("pdlts_raw", "PD-LTS raw", "pdlts_raw"),
        ("pdlts_density", "PD-LTS density", "pdlts_density"),
        ("pdlts_vh_snap0", "PD-LTS vh_snap0", "pdlts_vh_snap0"),
    ]
    clouds = {}
    for key, _, _ in panels:
        path = resolve_ply_ext(GC2026_ROOT, key, pick)
        xyz, rgb = read_ply_xyz_rgb(str(path), max_points=args.max_points, rng=np.random.RandomState(42))
        clouds[key] = (xyz, rgb)

    he_path = (
        GC2026_ROOT / "data/raw/UVG-CWI-DQPC" / pick.sequence
        / "high-end_capture_system/HE/15fps" / pick.he_name
    )
    he_xyz, he_rgb = read_ply_xyz_rgb(str(he_path), max_points=args.max_points, rng=np.random.RandomState(42))
    sp_path = resolve_ply_ext(GC2026_ROOT, "superpc_blend_cg", pick)
    sp_xyz, _ = read_ply_xyz_rgb(str(sp_path), max_points=args.max_points, rng=np.random.RandomState(42))
    c1, h1, c2, h2 = choose_zoom_boxes(he_xyz, sp_xyz, clouds["pdlts_vh_snap0"][0])
    boxes = [(c1, h1), (c2, h2)]

    fig, axes = plt.subplots(1, 3, figsize=(11, 3.6), dpi=args.dpi)
    fig.subplots_adjust(wspace=0.04, left=0.02, right=0.98, top=0.82, bottom=0.06)
    fig.suptitle(
        f"Refine ablation — {pick.sequence} / {pick.enh_name}  (raw → density → vh_snap0)",
        fontsize=11,
        y=0.98,
    )
    for ax, (key, title, mk) in zip(axes, panels):
        xyz, rgb = clouds[key]
        draw_panel(ax, xyz, rgb, title, args.elev, args.azim, pick.chamfer.get(mk), boxes=boxes, s=0.12)
        draw_inset(fig, ax, xyz, rgb, c1, h1, args.elev, args.azim, loc="upper left")
        draw_inset(fig, ax, xyz, rgb, c2, h2, args.elev, args.azim, loc="lower right")

    out_png = out_dir / f"ablation_refine_{tag_from_pick(pick)}.png"
    fig.savefig(out_png, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    return out_png


def load_summary() -> dict:
    return json.loads(SUMMARY_JSON.read_text(encoding="utf-8"))


def cg_baseline_per_seq() -> Dict[str, float]:
    pairs_path = GC2026_ROOT / "data/processed/val_pairs_official_cgv2.txt"
    by_file: Dict[str, float] = {}
    with open(CG_BASELINE_CSV, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            by_file[row["test_file"]] = float(row["chamfer_distance"])
    out: Dict[str, List[float]] = {s: [] for s in VAL_SEQS}
    with open(pairs_path, encoding="utf-8") as f:
        for line in f:
            parts = line.strip().split("\t")
            if not parts:
                continue
            cg_path = parts[0]
            if "/UVG-CWI-DQPC/" not in cg_path:
                continue
            seq = cg_path.split("/UVG-CWI-DQPC/")[1].split("/")[0]
            if seq not in out:
                continue
            fname = Path(cg_path).name
            if fname in by_file:
                out[seq].append(by_file[fname])
    return {s: float(np.mean(v)) for s, v in out.items() if v}


def per_seq_from_csv(csv_rel: str) -> Dict[str, float]:
    if csv_rel.startswith("docs/meeting_delivery/"):
        path = GC2026_ROOT / csv_rel
    else:
        path = GC2026_ROOT / "docs/meeting_delivery" / csv_rel
    return per_seq_from_csv_path(path)


def per_seq_from_csv_path(path) -> Dict[str, float]:
    acc: Dict[str, List[float]] = {s: [] for s in VAL_SEQS}
    with open(path, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            seq = row.get("sequence", "")
            if seq in acc:
                acc[seq].append(float(row["chamfer_distance"]))
    return {s: float(np.mean(v)) for s, v in acc.items() if v}


def fig_bar_per_seq(out_dir: Path, args) -> Path:
    summary = load_summary()
    cg_seq = cg_baseline_per_seq()
    cg_global = float(np.mean(list(cg_seq.values())))

    resolved = [("cg", "CG", cg_seq, cg_global)]
    short = {
        "superpc_only": "SuperPC",
        "pdlts_frozen_only": "PD-LTS",
        "pdlts_finetune_only": "PD-LTS-FT",
        "fusion_frozen_pdlts": "Hybrid",
        "fusion_finetune_pdlts": "Submit",
    }
    for m in summary.get("models", []):
        name = m.get("name", "")
        label = short.get(name) or m.get("label") or name
        ps = m.get("per_sequence_mean_chamfer") or {}
        csv_rel = m.get("csv", "")
        if csv_rel.startswith("docs/meeting_delivery/"):
            csv_path = GC2026_ROOT / csv_rel
        elif csv_rel:
            csv_path = GC2026_ROOT / "docs/meeting_delivery" / csv_rel
        else:
            csv_path = None
        if len(ps) < len(VAL_SEQS) and csv_path and csv_path.is_file():
            ps = per_seq_from_csv_path(csv_path)
        resolved.append((m["name"], label, ps, m["mean_chamfer_distance"]))
    models = resolved

    x = np.arange(len(VAL_SEQS))
    width = 0.14
    colors = ["#888888", "#d62728", "#ff9896", "#2ca02c", "#9467bd", "#1f77b4"]
    fig, ax = plt.subplots(figsize=(10, 4.5), dpi=args.dpi)
    for i, (name, label, per_seq, global_mean) in enumerate(models):
        if name == "cg":
            vals = [cg_seq[s] for s in VAL_SEQS]
        else:
            vals = [per_seq[s] for s in VAL_SEQS]
        offset = (i - len(models) / 2 + 0.5) * width
        bars = ax.bar(x + offset, vals, width, label=f"{label} ({global_mean:.2f})" if global_mean else label, color=colors[i % len(colors)])
        for bar, v in zip(bars, vals):
            ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 0.08, f"{v:.2f}", ha="center", va="bottom", fontsize=6)

    ax.set_xticks(x)
    ax.set_xticklabels(VAL_SEQS)
    ax.set_ylabel("Chamfer distance (mm)")
    ax.set_title("val565 per-sequence mean Chamfer (aligned HE)")
    ax.legend(loc="upper right", fontsize=7, ncol=2)
    ax.set_ylim(12, 22)
    ax.grid(axis="y", alpha=0.3)
    out_png = out_dir / "bar_per_sequence_chamfer.png"
    fig.savefig(out_png, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    return out_png


def load_csv_chamfer(csv_rel: str) -> Dict[Tuple[str, str], dict]:
    return load_metric_rows(csv_rel)


def fig_frame_diff(out_dir: Path, args) -> Path:
    sp = load_csv_chamfer(METRIC_CSVS["superpc_blend_cg"])
    density = load_csv_chamfer(METRIC_CSVS_EXTRA["pdlts_density"])
    fig, axes = plt.subplots(3, 1, figsize=(12, 8), dpi=args.dpi, sharex=True)
    for ax, seq in zip(axes, VAL_SEQS):
        frames, diffs = [], []
        for key in sorted(sp.keys(), key=lambda k: int(k[1])):
            if key[0] != seq:
                continue
            d = float(sp[key]["chamfer_distance"]) - float(density[key]["chamfer_distance"])
            frames.append(int(key[1]))
            diffs.append(d)
        ax.plot(frames, diffs, linewidth=0.8, color="#d62728")
        ax.axhline(0, color="k", linewidth=0.5, linestyle="--")
        ax.set_ylabel("Δ CD (mm)")
        ax.set_title(f"{seq}: SuperPC − density")
        ax.grid(alpha=0.3)
        if seq == "VirtualLife":
            tail = [f for f, dd in zip(frames, diffs) if f >= 400]
            if tail:
                ax.axvspan(min(tail), max(frames), alpha=0.12, color="orange", label="tail (frame≥400)")
                ax.legend(fontsize=8, loc="upper left")
    axes[-1].set_xlabel("val565 frame index")
    fig.suptitle("Per-frame Chamfer gap: SuperPC blend_cg minus PD-LTS density", y=0.995)
    fig.tight_layout()
    out_png = out_dir / "curve_superpc_minus_density.png"
    fig.savefig(out_png, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    return out_png


def fig_acc_comp(out_dir: Path, args) -> Path:
    summary = load_summary()
    model_names = ["superpc_blend_cg", "pdlts_raw", "pdlts_density_no_vh_tune", "pdlts_vh_snap0"]
    labels = ["SuperPC", "raw", "density", "vh_snap0"]
    acc_g, comp_g, cd_g = [], [], []
    for mn, lb in zip(model_names, labels):
        for m in summary["models"]:
            if m["name"] != mn:
                continue
            csv_path = GC2026_ROOT / m["csv"]
            accs, comps = [], []
            with open(csv_path, newline="", encoding="utf-8") as f:
                for row in csv.DictReader(f):
                    accs.append(float(row["accuracy"]))
                    comps.append(float(row["completeness"]))
            acc_g.append(np.mean(accs))
            comp_g.append(np.mean(comps))
            cd_g.append(m["mean_chamfer_distance"])

    x = np.arange(len(labels))
    w = 0.35
    fig, ax = plt.subplots(figsize=(8, 4.5), dpi=args.dpi)
    ax.bar(x - w / 2, acc_g, w, label="accuracy (→ HE)", color="#1f77b4")
    ax.bar(x + w / 2, comp_g, w, label="completeness (← HE)", color="#ff7f0e")
    for i, (a, c, cd) in enumerate(zip(acc_g, comp_g, cd_g)):
        ax.text(i, max(a, c) + 0.15, f"CD={cd:.2f}", ha="center", fontsize=8)
    ax.set_xticks(x)
    ax.set_xticklabels(labels)
    ax.set_ylabel("mm")
    ax.set_title("val565 global mean: accuracy vs completeness decomposition")
    ax.legend()
    ax.grid(axis="y", alpha=0.3)
    out_png = out_dir / "bar_accuracy_completeness.png"
    fig.savefig(out_png, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    return out_png


def point_stats_for_ply(path: Path, sor: bool = True) -> dict:
    xyz, rgb = read_ply_xyz_rgb(str(path))
    n_raw = int(xyz.shape[0])
    inlier_ratio = 1.0
    n_sor = n_raw
    if sor:
        fxyz, _ = filter_cg_outliers(xyz, rgb, nb_neighbors=20, std_ratio=2.0)
        n_sor = int(fxyz.shape[0])
        inlier_ratio = n_sor / max(n_raw, 1)
    return {"n_points": n_raw, "n_after_sor": n_sor, "inlier_ratio": inlier_ratio}


def fig_point_stats(pick: FramePick, out_dir: Path, args) -> Path:
    cg_path = (
        GC2026_ROOT / "data/raw/UVG-CWI-DQPC" / pick.sequence
        / "consumer-grade_capture_system/CG/15fps" / pick.cg_name
    )
    methods = [
        ("cg", cg_path, True),
        ("superpc_blend_cg", resolve_ply_ext(GC2026_ROOT, "superpc_blend_cg", pick), False),
        ("pdlts_raw", resolve_ply_ext(GC2026_ROOT, "pdlts_raw", pick), False),
        ("pdlts_density", resolve_ply_ext(GC2026_ROOT, "pdlts_density", pick), False),
    ]
    names, counts, inliers = [], [], []
    for key, path, sor in methods:
        st = point_stats_for_ply(path, sor=sor)
        names.append(MODEL_LABELS.get(key, key))
        counts.append(st["n_points"])
        inliers.append(st["inlier_ratio"] * 100)

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(10, 4), dpi=args.dpi)
    x = np.arange(len(names))
    ax1.bar(x, np.array(counts) / 1e6, color=["#888", "#d62728", "#ff9896", "#2ca02c"])
    ax1.set_xticks(x)
    ax1.set_xticklabels(names, rotation=15, ha="right")
    ax1.set_ylabel("Points (millions)")
    ax1.set_title(f"Output point count — {pick.sequence} / {pick.enh_name}")

    ax2.bar(x, inliers, color=["#888", "#d62728", "#ff9896", "#2ca02c"])
    ax2.set_xticks(x)
    ax2.set_xticklabels(names, rotation=15, ha="right")
    ax2.set_ylabel("SOR inlier ratio (%)")
    ax2.set_title("CG: SOR retain rate; ENH: pseudo inlier vs self")
    ax2.set_ylim(0, 105)
    fig.tight_layout()
    out_png = out_dir / f"stats_points_{tag_from_pick(pick)}.png"
    fig.savefig(out_png, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    return out_png


def fig_pipeline(out_dir: Path, args) -> Path:
    fig, ax = plt.subplots(figsize=(11, 2.8), dpi=args.dpi)
    ax.set_xlim(0, 10)
    ax.set_ylim(0, 3)
    ax.axis("off")
    boxes = [
        (0.2, 1.0, "Official CG\nPLY v2"),
        (2.0, 1.0, "PD-LTS light\n(frozen θ)"),
        (3.8, 1.0, "KNN\ncolor"),
        (5.4, 1.0, "Snap\n1.0 mm"),
        (7.0, 1.0, "Density-adaptive\nfill 0.6 mm"),
        (8.6, 1.0, "ENH\noutput"),
    ]
    for i, (x, y, text) in enumerate(boxes):
        ax.add_patch(FancyBboxPatch((x, y), 1.35, 0.85, boxstyle="round,pad=0.04", facecolor="#e8f4fc", edgecolor="#333"))
        ax.text(x + 0.67, y + 0.42, text, ha="center", va="center", fontsize=8)
        if i < len(boxes) - 1:
            ax.add_patch(FancyArrowPatch((x + 1.38, y + 0.42), (boxes[i + 1][0] - 0.05, y + 0.42),
                                         arrowstyle="->", mutation_scale=12, color="#333"))
    ax.text(5, 2.35, "Submission pipeline: CG-preserving geometric refinement (training-free φ)", ha="center", fontsize=11, weight="bold")
    ax.text(5, 0.35, r"$\hat{P}_{ENH} = \mathcal{R}_\phi(\mathcal{G}_\theta(P_{CG}), P_{CG})$", ha="center", fontsize=10)
    out_png = out_dir / "diagram_pipeline_pdlts_density.png"
    fig.savefig(out_png, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    return out_png


def pick_vh_ablation_frame() -> FramePick:
    density = load_metric_rows(METRIC_CSVS_EXTRA["pdlts_density"])
    vh = load_metric_rows(METRIC_CSVS["pdlts_vh_snap0"])
    best_key, best_gap = None, -1.0
    for key in density:
        if key[0] != "VictoryHeart":
            continue
        gap = abs(float(vh[key]["chamfer_distance"]) - float(density[key]["chamfer_distance"]))
        if gap > best_gap:
            best_gap = gap
            best_key = key
    seq, fidx = best_key
    row = density[best_key]
    enh = row["test_file"]
    return FramePick(
        sequence=seq,
        frame_idx=fidx,
        enh_name=enh,
        cg_name=enh.replace("_ENH_", "_CG_"),
        he_name=row["gt_file"],
        chamfer={
            "pdlts_density": float(density[best_key]["chamfer_distance"]),
            "pdlts_vh_snap0": float(vh[best_key]["chamfer_distance"]),
        },
        gap_superpc_minus_vh=best_gap,
    )


def fig_vh_closeup(out_dir: Path, args) -> Path:
    pick = pick_vh_ablation_frame()
    panels = [
        ("pdlts_density", "PD-LTS density (submit)", "pdlts_density"),
        ("pdlts_vh_snap0", "vh_snap0 (VH snap=0)", "pdlts_vh_snap0"),
    ]
    clouds = {}
    for key, _, _ in panels:
        path = resolve_ply_ext(GC2026_ROOT, key, pick)
        xyz, rgb = read_ply_xyz_rgb(str(path), max_points=args.max_points, rng=np.random.RandomState(42))
        clouds[key] = (xyz, rgb)

    fig, axes = plt.subplots(1, 2, figsize=(8, 3.8), dpi=args.dpi)
    fig.subplots_adjust(wspace=0.05, top=0.82, bottom=0.06)
    fig.suptitle(
        f"VictoryHeart ablation — {pick.enh_name}  "
        f"(density={pick.chamfer['pdlts_density']:.2f} vs vh={pick.chamfer['pdlts_vh_snap0']:.2f} mm)",
        fontsize=10,
        y=0.98,
    )
    for ax, (key, title, mk) in zip(axes, panels):
        xyz, rgb = clouds[key]
        draw_panel(ax, xyz, rgb, title, args.elev, args.azim, pick.chamfer.get(mk), s=0.15)

    out_png = out_dir / f"vh_closeup_{tag_from_pick(pick)}.png"
    fig.savefig(out_png, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    return out_png


FIGURE_FNS = {
    "heatmap": lambda pick, out_dir, args: fig_heatmap(pick, out_dir, args),
    "ablation": lambda pick, out_dir, args: fig_ablation(pick, out_dir, args),
    "bar_per_seq": lambda pick, out_dir, args: fig_bar_per_seq(out_dir, args),
    "frame_diff": lambda pick, out_dir, args: fig_frame_diff(out_dir, args),
    "acc_comp": lambda pick, out_dir, args: fig_acc_comp(out_dir, args),
    "point_stats": lambda pick, out_dir, args: fig_point_stats(pick, out_dir, args),
    "pipeline": lambda pick, out_dir, args: fig_pipeline(out_dir, args),
    "vh_closeup": lambda pick, out_dir, args: fig_vh_closeup(out_dir, args),
}

PRIORITY_ORDER = [
    "heatmap", "ablation", "bar_per_seq",
    "frame_diff", "acc_comp", "point_stats", "pipeline", "vh_closeup",
]


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--out-dir", default=str(FIGURES_DIR))
    p.add_argument("--figures", default="all", help="Comma list or 'all' or 'priority' (②③④)")
    p.add_argument("--frame-meta", default="", help="JSON from qualitative figure for fixed frame")
    p.add_argument("--max-points", type=int, default=100000)
    p.add_argument("--vmax-mm", type=float, default=50.0)
    p.add_argument("--elev", type=float, default=18.0)
    p.add_argument("--azim", type=float, default=-68.0)
    p.add_argument("--dpi", type=int, default=200)
    args = p.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    meta_path = Path(args.frame_meta) if args.frame_meta else None
    if meta_path is None:
        default_meta = FIGURES_DIR / "qualitative_VirtualLife_431_VirtualLife_UVG-CWI-DQPC_ENH_15_0_195_0063.json"
        if default_meta.is_file():
            meta_path = default_meta
    pick = load_frame_meta(meta_path)

    if args.figures == "all":
        figs = PRIORITY_ORDER
    elif args.figures == "priority":
        figs = PRIORITY_ORDER[:3]
    else:
        figs = [f.strip() for f in args.figures.split(",")]

    results = []
    for name in figs:
        if name not in FIGURE_FNS:
            raise SystemExit(f"Unknown figure: {name}")
        print(f"[figures] rendering {name}...")
        path = FIGURE_FNS[name](pick, out_dir, args)
        results.append({"figure": name, "path": str(path)})
        print(f"  -> {path}")

    manifest = {"frame": tag_from_pick(pick), "figures": results}
    manifest_path = out_dir / "figures_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
