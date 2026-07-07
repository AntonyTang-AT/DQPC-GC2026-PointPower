#!/usr/bin/env bash
# Push PointPower submission and open PR to UVG-CWI/submissions.
#
# Prerequisites:
#   1. GitHub account with fork of https://github.com/UVG-CWI/submissions
#   2. gh auth login   OR   export GITHUB_TOKEN=ghp_...
#
# Usage:
#   bash scripts/push_pointpower_pr.sh
#   bash scripts/push_pointpower_pr.sh YOUR_GITHUB_USERNAME
set -euo pipefail

GC2026_ROOT="${GC2026_ROOT:-/root/autodl-tmp/GC2026}"
PREP="${GC2026_ROOT}/output/github_pr_prep/submissions_repo"
GH_USER="${1:-}"
UPSTREAM="https://github.com/UVG-CWI/submissions.git"

if [[ ! -d "$PREP/.git" ]]; then
  echo "Missing prepared repo: $PREP" >&2
  echo "Run preparation first (see output/github_pr_prep/README_PR.md)" >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    echo "$GITHUB_TOKEN" | gh auth login --with-token
  else
    echo "Not logged in. Run: gh auth login" >&2
    echo "Or: export GITHUB_TOKEN=ghp_... && bash $0" >&2
    exit 1
  fi
fi

if [[ -z "$GH_USER" ]]; then
  GH_USER="$(gh api user -q .login)"
fi

FORK="https://github.com/${GH_USER}/submissions.git"
cd "$PREP"

if ! git remote get-url fork >/dev/null 2>&1; then
  git remote add fork "$FORK"
fi
git remote set-url fork "$FORK"

echo "[push] Creating fork if needed..."
gh repo fork UVG-CWI/submissions --clone=false --remote=false 2>/dev/null || true

echo "[push] Pushing branch pointpower-enhancement-only to fork..."
git push -u fork pointpower-enhancement-only --force

echo "[push] Opening PR..."
gh pr create \
  --repo UVG-CWI/submissions \
  --head "${GH_USER}:pointpower-enhancement-only" \
  --base main \
  --title "PointPower — Enhancement Only submission" \
  --body-file "${GC2026_ROOT}/output/github_pr_prep/PR_BODY.md"

echo "[push] DONE"
