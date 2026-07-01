#!/usr/bin/env bash
# Fine-tuned PD-LTS → val565 infer + density refine + eval (sequential).
#
#   bash scripts/run_pdlts_finetune_val565_pipeline.sh bg
#   bash scripts/run_pdlts_finetune_val565_pipeline.sh all
#   STAGE=refine bash scripts/run_pdlts_finetune_val565_pipeline.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="${PDLTS_FT_ROOT:-$ROOT/output/pdlts_finetune_uvg}"
GEOM_DIR="${GEOM_DIR:-$BASE/val565/light}"
REFINE_OUT="${REFINE_OUT:-$BASE/val565_refine/pdlts_light_snap1_fill0.6_density}"
PRESET="${PRESET:-pdlts_light_snap1_fill0.6_density}"
CG_LIST="${CG_LIST:-$ROOT/data/processed/val_cg_only_official_cgv2.txt}"
PAIRS="${PAIRS:-$ROOT/data/processed/val_pairs_official_cgv2.txt}"
LOGDIR="${LOGDIR:-$BASE/logs/pipeline}"
STATUS="${STATUS:-$BASE/pipeline_status.json}"
STAGE="${STAGE:-all}"
EVAL_WORKERS="${EVAL_WORKERS:-16}"
MAX_EVAL_WORKERS="${MAX_EVAL_WORKERS:-16}"

mkdir -p "$LOGDIR" "$(dirname "$REFINE_OUT")"

source /root/miniconda3/etc/profile.d/conda.sh
conda activate superpc
export PYTHONPATH="$ROOT/scripts:${PYTHONPATH:-}"

log() { echo "[pdlts_ft_pipe] $(date +%H:%M:%S) $*" | tee -a "$LOGDIR/pipeline.log"; }

write_status() {
  local phase="$1"
  python3 - <<PY
import json, glob, os, time
base = "$BASE"
geom = "$GEOM_DIR"
refine = "$REFINE_OUT"
total = 565
seqs = ["TrumanShow", "VictoryHeart", "VirtualLife"]
seq_totals = {"TrumanShow": 172, "VictoryHeart": 197, "VirtualLife": 196}

def count(d):
    out = {s: len(glob.glob(os.path.join(d, s, "*.ply"))) for s in seqs}
    out["total"] = sum(out.values())
    return out

def cd(path):
    if not os.path.isfile(path):
        return None
    d = json.load(open(path))
    s = d.get("summary", d)
    return (s.get("means") or {}).get("chamfer_distance") or s.get("mean_enh_chamfer_distance")

payload = {
    "updated": time.strftime("%Y-%m-%d %H:%M:%S"),
    "phase": "$phase",
    "ckpt": os.environ.get("PDLTS_CKPT", ""),
    "geom_dir": geom,
    "refine_out": refine,
    "preset": "$PRESET",
    "pdlts_infer": count(geom),
    "refine": count(refine),
    "refine_infer_meta": os.path.isfile(os.path.join(refine, "infer_meta.json")),
    "eval_done": os.path.isfile(os.path.join(refine, "evaluation_gc_baseline_val565.json")),
    "chamfer_mm": cd(os.path.join(refine, "evaluation_gc_baseline_val565.json")),
    "seq_totals": seq_totals,
}
json.dump(payload, open("$STATUS", "w"), indent=2)
PY
}

wait_pdlts_infer() {
  local target=565
  log "wait PD-LTS infer ($GEOM_DIR)"
  while true; do
    local n
    n=$(find "$GEOM_DIR" -name '*.ply' 2>/dev/null | wc -l)
    write_status "pdlts_infer"
    log "  infer ${n}/${target}"
    if [[ "$n" -ge "$target" ]]; then
      break
    fi
    if ! pgrep -f "run_pdlts_infer.py.*${GEOM_DIR}" >/dev/null 2>&1; then
      if [[ "$n" -lt "$target" ]]; then
        log "WARN: infer workers stopped at ${n}/${target}"
      fi
      break
    fi
    sleep 30
  done
}

stage_infer() {
  write_status "pdlts_infer_start"
  bash "$ROOT/scripts/run_pdlts_finetune_val565_infer.sh"
  wait_pdlts_infer
  write_status "pdlts_infer_done"
}

stage_refine() {
  local n
  n=$(find "$GEOM_DIR" -name '*.ply' 2>/dev/null | wc -l)
  [[ "$n" -ge 565 ]] || { log "refine blocked: infer ${n}/565"; exit 1; }
  if [[ -f "$REFINE_OUT/infer_meta.json" ]] && [[ $(find "$REFINE_OUT" -name '*.ply' | wc -l) -ge 565 ]]; then
    log "skip refine (done)"
    write_status "refine_done"
    return 0
  fi
  write_status "refine_start"
  log "refine preset=$PRESET geom=$GEOM_DIR -> $REFINE_OUT"
  PRESET="$PRESET" OUT_DIR="$REFINE_OUT" GEOMETRY_DIR="$GEOM_DIR" \
    CG_LIST="$CG_LIST" LOGDIR="$LOGDIR/refine_shards" \
    NUM_SHARDS="${NUM_SHARDS:-32}" \
    bash "$ROOT/scripts/run_enh_refine_sharded.sh" \
    >> "$LOGDIR/refine.log" 2>&1
  write_status "refine_done"
}

stage_eval() {
  local ev="$REFINE_OUT/evaluation_gc_baseline_val565.json"
  if [[ -f "$ev" ]]; then
    log "skip eval (done)"
    write_status "eval_done"
    return 0
  fi
  write_status "eval_start"
  log "eval workers=$EVAL_WORKERS -> $ev"
  nice -n 10 env GC2026_EVAL_PARALLEL=1 \
    OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1 \
    python "$ROOT/scripts/evaluate_gc_baseline_metrics.py" \
    --pairs-file "$PAIRS" \
    --test-root "$REFINE_OUT" \
    --test-mode enh \
    --workers "$EVAL_WORKERS" \
    --also-cg \
    --out-json "$ev" \
    --out-csv "$REFINE_OUT/evaluation_gc_baseline_val565.csv" \
    >> "$LOGDIR/eval.log" 2>&1
  write_status "eval_done"
}

run_all() {
  log "pipeline start BASE=$BASE PRESET=$PRESET"
  export PDLTS_CKPT="${PDLTS_CKPT:-$(ls -t "$BASE"/run_*/DenoiseFlow-light-UVG-finetune.ckpt 2>/dev/null | head -1)}"
  export PDLTS_OUT="$GEOM_DIR"
  log "ckpt=$PDLTS_CKPT"
  stage_infer
  stage_refine
  stage_eval
  write_status "done"
  log "pipeline DONE"
  bash "$ROOT/scripts/show_pdlts_finetune_val565_progress.sh"
}

case "${1:-${STAGE}}" in
  bg)
    nohup env STAGE=all bash "$0" all >> "$LOGDIR/pipeline_nohup.log" 2>&1 &
    echo "[pdlts_ft_pipe] pid=$! log=$LOGDIR/pipeline_nohup.log status=$STATUS"
    sleep 2
    bash "$ROOT/scripts/show_pdlts_finetune_val565_progress.sh"
    ;;
  infer) stage_infer ;;
  refine) stage_refine ;;
  eval) stage_eval ;;
  all|full) run_all ;;
  status) bash "$ROOT/scripts/show_pdlts_finetune_val565_progress.sh" ;;
  *)
    echo "Usage: $0 {bg|all|infer|refine|eval|status}" >&2
    exit 1
    ;;
esac
