"""Apply Pearl's source-proven Mid-to-B step correction to composed candidates."""
import argparse
from pathlib import Path
from apply_reviewed_wall_opening import compile_review

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--attack', type=Path, required=True)
    parser.add_argument('--defense', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    compile_review(Path(__file__).with_name('data') / 'pearl-mid-step-review-2026-09-15.json',
                   {'attack': args.attack, 'defense': args.defense}, args.output)
