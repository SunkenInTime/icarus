"""Apply individually reviewed ceiling and boundary exclusions to frozen assets."""
import argparse
import copy
import gzip
import hashlib
import json
from pathlib import Path

REVIEW = Path('scripts/data/systematic-roof-review-2026-09-13.json')


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def read(path):
    raw = Path(path).read_bytes()
    return json.loads(gzip.decompress(raw) if str(path).endswith('.gz') else raw)


def build(output, review_path=REVIEW):
    review = read(review_path)
    output.mkdir(parents=True, exist_ok=False)
    results = []
    for name, spec in review['maps'].items():
        source_path = Path(spec['standingSource'])
        assert sha(source_path) == spec['standingSourceSha256']
        assert all(sha(path) == digest for path, digest in spec['sourceSha256'].items())
        source = read(source_path)
        excluded = {row['domain']['id']: row['domain'] for row in spec['excludedStandingDomains']}
        assert all(next(d for d in source['domains'] if d['id'] == key) == value
                   for key, value in excluded.items())
        source['domains'] = [d for d in source['domains'] if d['id'] not in excluded]
        source['systematicRoofReviewSha256'] = sha(review_path)
        folder = output / name
        source_dir = folder / 'source'
        source_dir.mkdir(parents=True)
        (source_dir / 'regional-floors.json').write_text(json.dumps(source, indent=2) + '\n')
        (source_dir / 'source-inventory.json').write_bytes(source_path.with_name('source-inventory.json').read_bytes())
        support_ids = {sid for row in spec['excludedStandingDomains'] for sid in row['supportIds']}
        sides = []
        for side, expected in spec['baselineSha256'].items():
            path = Path(f'assets/maps/{name}_svg_height_{side}.json.gz')
            assert sha(path) == expected
            (folder / f'before-{side}.json.gz').write_bytes(path.read_bytes())
            before = read(path)
            model = copy.deepcopy(before)
            removed = [s for s in model['supports'] if s['id'] in support_ids]
            assert {s['id'] for s in removed} == support_ids
            model['supports'] = [s for s in model['supports'] if s['id'] not in support_ids]
            # Wall positions/heights, receiver, ground, and every retained support
            # remain exactly as they were before this role correction.
            assert all(model[k] == before[k] for k in before if k != 'supports')
            target = folder / f'candidate-{side}.json.gz'
            target.write_bytes(gzip.compress(json.dumps(model, separators=(',', ':'), allow_nan=False).encode(), mtime=0))
            sides.append(dict(side=side, beforeSha256=expected, candidateSha256=sha(target),
                              removedSupportIds=sorted(support_ids), otherFieldsUnchanged=True))
        results.append(dict(map=name, excludedDomainIds=sorted(excluded), sides=sides,
                            sourceSha256=sha(source_dir / 'regional-floors.json')))
    (output / 'application.json').write_text(json.dumps(dict(reviewSha256=sha(review_path),
        algorithmSha256=sha(Path(__file__)), maps=results), indent=2) + '\n')
    print(json.dumps(results), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--review', type=Path, default=REVIEW)
    args = parser.parse_args()
    build(args.output, args.review)
