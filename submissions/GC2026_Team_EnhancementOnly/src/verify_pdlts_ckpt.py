#!/usr/bin/env python3
"""Smoke-check PD-LTS light checkpoint loads."""
from __future__ import annotations

import argparse
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--ckpt-path", required=True)
    args = p.parse_args()
    if not os.path.isfile(args.ckpt_path):
        raise SystemExit(f"missing: {args.ckpt_path}")
    import run_pdlts_infer as pdlts  # noqa: WPS433

    get_net, _, _ = pdlts.load_denoise_module("light")
    net = get_net(args.ckpt_path)
    print("OK", type(net).__name__, args.ckpt_path)


if __name__ == "__main__":
    main()
