"""Attach reviewed heights to existing SVG components without changing their ink."""
import argparse
import copy
import gzip
import hashlib
import json
from pathlib import Path

REV = Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')


def read(path):
    return json.loads(path.read_bytes())


def write(path, value):
    path.write_text(json.dumps(value, separators=(',', ':'), allow_nan=False) + '\n')


def stamp(path):
    return dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', type=Path, default=REV/'split-svg-semantic-prototype-v2')
    parser.add_argument('--annotations', type=Path, required=True)
    parser.add_argument('--out', type=Path, default=REV/'split-svg-semantic-prototype-v3')
    args = parser.parse_args()
    extension = read(args.annotations)
    assert extension['annotations'], 'No annotations supplied.'
    args.out.mkdir(exist_ok=False)
    reports = []
    for side in ['attack', 'defense']:
        base = read(args.base/f'split-{side}.json')
        model = copy.deepcopy(base)
        walls = {wall['id']: wall for wall in model['walls']}
        changed = []
        support_ids = {s['id'] for s in model['supports']}
        for annotation in extension['annotations']:
            assert annotation['bands'] and annotation['evidence']
            for wall_id in annotation['wallsBySide'][side]:
                assert wall_id not in changed, 'Overlapping annotations.'
                wall = walls[wall_id]
                assert wall['unknownHeight'], 'Preserve previously reviewed decisions.'
                wall.update(bands=annotation['bands'], unknownHeight=False,
                            heightModel='source-measured-cover',
                            heightEvidence=annotation['evidence'],
                            annotationId=annotation['id'])
                changed.append(wall_id)
            support = annotation.get('supportsBySide', {}).get(side)
            if support:
                assert support['id'] not in support_ids
                support_ids.add(support['id'])
                model['supports'].append(support)
        for before, after in zip(base['walls'], model['walls']):
            assert before['id'] == after['id']
            assert before['rings'] == after['rings']
            assert before['fillRule'] == after['fillRule']
            if before['id'] not in changed:
                assert before == after
        assert model['receiver'] == base['receiver']
        model['annotationExtension'] = stamp(args.annotations)
        model['limitations'] = [
            'Unclassified wall heights remain explicitly unknown and opaque.',
            'Vent174 remains solid by gameplay review.',
            'Box tops use measured support planes over their authored SVG footprints.',
            'Connected ground is flat; separate stacked-floor selection is unfinished.',
        ]
        path = args.out/f'split-{side}.json'
        write(path, model)
        reports.append(dict(side=side, model=stamp(path),
                            bytes=path.stat().st_size,
                            gzipBytes=len(gzip.compress(path.read_bytes(), mtime=0)),
                            changedWallIds=changed,
                            classifiedComponents=sum(not w['unknownHeight'] for w in model['walls']),
                            unknownComponents=sum(w['unknownHeight'] for w in model['walls']),
                            supportCount=len(model['supports']),
                            wallGeometryAndReceiverUnchanged=True,
                            previousDecisionsUnchanged=True))
    (args.out/'source-height-evidence.json').write_bytes((args.base/'source-height-evidence.json').read_bytes())
    review = read(args.base/'review-poses.json')
    review['cases'].extend(extension['reviewCases'])
    assert len({(c['side'], c['id']) for c in review['cases']}) == len(review['cases'])
    write(args.out/'review-poses.json', review)
    write(args.out/'annotation-extension.json', extension)
    result = dict(base=str(args.base), extension=stamp(args.annotations), models=reports,
                  builder=stamp(Path(__file__)), productionMutation=False)
    write(args.out/'review.json', result)
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
