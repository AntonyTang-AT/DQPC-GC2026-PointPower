"""Resolve GC2026 workspace root from submission package or project scripts/."""
from __future__ import annotations

import os


def resolve_gc2026_root(script_dir: str) -> str:
    env = os.environ.get("GC2026_ROOT", "").strip()
    if env:
        return os.path.abspath(env)
    sub_root = os.path.dirname(os.path.abspath(script_dir))
    workspace = os.path.abspath(os.path.join(sub_root, "..", ".."))
    if os.path.isdir(os.path.join(workspace, "data")) and os.path.isdir(
        os.path.join(workspace, "code", "PD-LTS")
    ):
        return workspace
    if os.path.isdir(os.path.join(sub_root, "data")):
        return sub_root
    return workspace
