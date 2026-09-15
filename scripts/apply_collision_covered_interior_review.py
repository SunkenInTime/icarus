"""Compile the separate collision-body ceiling review with manual-only semantics.

Uses the same exact-preservation compiler as the earlier mesh-roof review, but
requires its own canonical review, frozen baselines, and fresh output directory.
"""
import argparse
from pathlib import Path
from apply_covered_interior_review import build


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--review', type=Path,
                        default=Path('scripts/data/collision-covered-interior-review-2026-09-14.json'))
    parser.add_argument('--assets-dir', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    build(args.output, args.review, args.assets_dir)
