"""Apply the reviewed Lotus small and stepped crate corrections and target floors."""
import argparse
import copy
import gzip
import json
from pathlib import Path

from apply_reviewed_prop_caps import compile_review as cap, read, sha
from apply_reviewed_wall_opening import compile_review as opening


def compile_reviews(inputs, output):
    output.mkdir(parents=True, exist_ok=True)
    data = Path(__file__).with_name('data')
    small = output / 'small-crate'
    stepped = output / 'stepped-crate'
    cap(data / 'lotus-small-crate-outline-review-2026-09-15.json', inputs, small)
    opening(data / 'lotus-stepped-crate-review-2026-09-15.json',
            {s: small / f'candidate-{s}.json.gz' for s in inputs}, stepped)
    review_path = data / 'lotus-lower-courtyard-projection-review-2026-09-15.json'
    review = read(review_path)
    for path, expected in review['sources'].items():
        assert sha(path) == expected, ('Changed source', path)
    reports = []
    for side in inputs:
        path = stepped / f'candidate-{side}.json.gz'
        before = read(path)
        assert sha(path) == review['sides'][side]['baselineSha256']
        for destination in review['sides'][side]['destinations']:
            expected = destination['expectedDestinationSupport']
            actual = next(s for s in before['supports'] if s['id'] == expected['id'])
            assert actual == expected, ('Changed target support', side, expected['id'])
        assert not before.get('sightlineFloorSupportIds')
        model = copy.deepcopy(before)
        model['sightlineFloorSupportIds'] = review['destinationSupportIds']
        model[review['stampKey']] = sha(review_path)
        target = output / f'candidate-{side}.json.gz'
        target.write_bytes(gzip.compress((json.dumps(model, separators=(',', ':')) + '\n').encode(), mtime=0))
        reports.append(dict(side=side, inputSha256=sha(inputs[side]), outputSha256=sha(target)))
    (output / 'lotus-remaining-build.json').write_text(json.dumps(dict(
        status='compiled', algorithmSha256=sha(__file__),
        projectionReviewSha256=sha(review_path), sides=reports), indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--attack', type=Path, required=True)
    parser.add_argument('--defense', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    compile_reviews({'attack': args.attack, 'defense': args.defense}, args.output)
