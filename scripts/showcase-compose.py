#!/usr/bin/env python3
"""Copies a showcase run's captures into docs/screenshots.

usage: scripts/showcase-compose.py RUN_DIR [OUT_DIR]   (default docs/screenshots)

capture-showcase-NN-name.png -> NN-name.png. Pictures from an earlier set
that this run did not make are removed, so the folder matches the README.
"""
import shutil
import sys
from pathlib import Path

PREFIX = "capture-showcase-"


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    run = Path(sys.argv[1])
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(__file__).resolve().parent.parent / "docs" / "screenshots"
    captures = sorted(run.glob(f"{PREFIX}*.png")) if run.is_dir() else []
    if not captures:
        print(f"no showcase captures in {run}", file=sys.stderr)
        return 1
    out.mkdir(parents=True, exist_ok=True)
    names = {capture.name[len(PREFIX):] for capture in captures}
    for stale in out.glob("[0-9][0-9]-*.png"):
        if stale.name not in names:
            stale.unlink()
    for capture in captures:
        shutil.copyfile(capture, out / capture.name[len(PREFIX):])
    print("\n".join(sorted(names)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
