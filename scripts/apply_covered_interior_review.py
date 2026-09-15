"""Preserve reviewed roof levels while excluding them from automatic standing.

Physical collision and measured domain records remain intact. This applies a
recorded gameplay default decision; it does not declare roofs nonphysical.
"""
import argparse
import copy
import gzip
import hashlib
import json
from pathlib import Path

REVIEW = Path('scripts/data/covered-interior-gameplay-review-2026-09-14.json')


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def read(path):
    raw = Path(path).read_bytes()
    return json.loads(gzip.decompress(raw) if str(path).endswith('.gz') else raw)


def reviewed_source(source, decisions, review_sha):
    """Move exact evidence records; never replace them with synthetic floors."""
    automatic = {d['id']: d for d in source['domains']}
    manual = {d['id']: d for d in source.get('manualDomains', [])}
    assert len(automatic) == len(source['domains']), 'Duplicate automatic domain'
    assert len(manual) == len(source.get('manualDomains', [])), 'Duplicate manual domain'
    assert not automatic.keys() & manual.keys(), 'Conflicting domain dispositions'
    chosen = {row['domain']['id']: row['domain'] for row in decisions}
    assert len(chosen) == len(decisions), 'Duplicate reviewed domain'
    for key, domain in chosen.items():
        assert automatic.get(key) == domain, (key, 'Reviewed source domain differs')
    result = copy.deepcopy(source)
    result['domains'] = [d for d in result['domains'] if d['id'] not in chosen]
    result['manualDomains'] = [*result.get('manualDomains', []),
                               *[copy.deepcopy(d) for d in source['domains'] if d['id'] in chosen]]
    result['coveredInteriorReviewSha256'] = review_sha
    assert {d['id']: d for d in result['domains'] + result['manualDomains']} == {
        **automatic, **manual}, 'Physical evidence changed'
    return result, chosen


def reviewed_model(before, name, domain_ids, support_ids):
    assert not set(before.get('sightlineFloorSupportIds', [])) & support_ids, (
        name, 'A reviewed sightline destination requires automatic standing')
    result = copy.deepcopy(before)
    changed, present = [], []
    seen = set()
    for original, support in zip(before['supports'], result['supports']):
        sid = support['id']
        assert sid not in seen, (name, 'Duplicate runtime support', sid)
        seen.add(sid)
        prefix = f'{name}-measured-'
        if sid.startswith(prefix) and sid[len(prefix):] in domain_ids:
            assert sid in support_ids, (name, sid, 'Review omitted measured alias')
        if sid in support_ids:
            present.append(sid)
            support['automaticStandingAllowed'] = False
            if original.get('automaticStandingAllowed') is not False:
                changed.append(sid)
            assert {k: v for k, v in support.items() if k != 'automaticStandingAllowed'} == {
                k: v for k, v in original.items() if k != 'automaticStandingAllowed'}
        else:
            assert support == original
    assert all(result[k] == before[k] for k in before if k != 'supports')
    return result, sorted(present), sorted(changed)


def build(output, review_path=REVIEW, assets_dir=Path('assets/maps')):
    output, review_path, assets_dir = Path(output), Path(review_path), Path(assets_dir)
    assert not output.exists(), 'Choose a fresh output directory'
    review, review_sha = read(review_path), sha(review_path)
    prepared = []
    # Validate every input and proposal before writing any candidate.
    for name, spec in review['maps'].items():
        source_path = Path(spec['standingSource'])
        assert sha(source_path) == spec['standingSourceSha256'], (name, 'Standing source changed')
        for path, expected in spec['sourceSha256'].items():
            assert sha(path) == expected, (name, path, 'Physical source changed')
        decisions = spec['defaultExcludedStandingDomains']
        source, domains = reviewed_source(read(source_path), decisions, review_sha)
        support_ids = {sid for row in decisions for sid in row['supportIds']}
        assert set(spec['baselineSha256']) == {'attack', 'defense'}
        sides, found = [], set()
        for side, expected in spec['baselineSha256'].items():
            path = assets_dir / f'{name}_svg_height_{side}.json.gz'
            assert sha(path) == expected, (name, side, 'Baseline asset changed')
            model, present, changed = reviewed_model(read(path), name, domains, support_ids)
            found.update(present)
            sides.append((side, path, model, present, changed))
        assert found == support_ids, (name, 'Reviewed aliases absent from both sides', sorted(support_ids - found))
        prepared.append((name, spec, source_path, source, domains, sides))
    output.mkdir(parents=True)
    results = []
    for name, spec, source_path, source, domains, sides in prepared:
        folder = output / name
        source_dir = folder / 'source'
        source_dir.mkdir(parents=True)
        (folder / 'before-regional-floors.json').write_bytes(source_path.read_bytes())
        target_source = source_dir / 'regional-floors.json'
        target_source.write_text(json.dumps(source, indent=2, allow_nan=False) + '\n')
        inventory = source_path.with_name('source-inventory.json')
        if inventory.exists():
            (source_dir / inventory.name).write_bytes(inventory.read_bytes())
        side_results = []
        for side, path, model, present, changed in sides:
            (folder / f'before-{side}.json.gz').write_bytes(path.read_bytes())
            target = folder / f'candidate-{side}.json.gz'
            target.write_bytes(gzip.compress(json.dumps(model, separators=(',', ':'),
                allow_nan=False).encode(), mtime=0))
            side_results.append(dict(side=side, beforeSha256=spec['baselineSha256'][side],
                candidateSha256=sha(target), defaultExcludedSupportIds=present,
                changedSupportIds=changed, allOtherFieldsUnchanged=True))
        results.append(dict(map=name, manualDomainIds=sorted(domains),
            originalStandingSourceSha256=spec['standingSourceSha256'],
            sourceSha256=sha(target_source), physicalDomainEvidenceUnchanged=True,
            sourceInventoryCopied=inventory.exists(), sides=side_results))
    application = dict(reviewSha256=review_sha, algorithmSha256=sha(Path(__file__)), maps=results)
    (output / 'application.json').write_text(json.dumps(application, indent=2) + '\n')
    print(json.dumps(application), flush=True)
    return application


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--review', type=Path, default=REVIEW)
    parser.add_argument('--assets-dir', type=Path, default=Path('assets/maps'))
    args = parser.parse_args()
    build(args.output, args.review, args.assets_dir)
