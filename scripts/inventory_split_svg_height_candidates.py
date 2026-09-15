"""List nearby source objects for unclassified SVG walls; never assign heights.

Bounds overlap is a review aid, not proof of a wall association. Keep source XY
out of the runtime model and retain all existing gameplay decisions.
"""
import argparse
import json
from pathlib import Path

import numpy as np

ROOT = Path('E:/IcarusWorldAudit/2026-09-06')
REV = ROOT / 'tactical-visibility-revision'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    model = json.loads((REV / 'split-svg-semantic-prototype-v3/split-attack.json').read_text())
    metadata = json.loads((ROOT / 'supplemented-v2/world/split/geometry.json').read_text())
    transform = np.array(json.loads((ROOT / 'tactical-alignment-sides-v1/split.json').read_text())['nativeToAttackSvg'])
    objects = []
    for index, obj in enumerate(metadata['objects']):
        if any(word in obj['path'].lower() for word in ('foliage', 'bush', 'leaf', 'grass')):
            continue
        bounds = np.array(obj['boundsMeters'])
        projected = np.c_[bounds[:, :2], np.ones(2)] @ transform.T
        objects.append((index, obj, projected.min(0), projected.max(0)))
    rows = []
    for wall in model['walls']:
        if not wall['unknownHeight']:
            continue
        points = np.concatenate([np.array(r).reshape(-1, 2) for r in wall['rings']])
        low, high = points.min(0), points.max(0)
        candidates = []
        for index, obj, obj_low, obj_high in objects:
            overlap = np.maximum(0, np.minimum(high, obj_high) - np.maximum(low, obj_low))
            if not np.all(overlap > 0):
                continue
            # Smaller enclosing objects appear first; this does not establish identity.
            extent = obj_high - obj_low
            candidates.append(dict(object=index, path=obj['path'],
                                   boundsMeters=obj['boundsMeters'],
                                   projectedBoundsSvg=[obj_low.tolist(), obj_high.tolist()],
                                   boundsAreaSvg=float(np.prod(extent))))
        candidates.sort(key=lambda c: c['boundsAreaSvg'])
        rows.append(dict(wallId=wall['id'], sourcePathIndex=wall['sourcePathIndex'],
                         boundsSvg=[low.tolist(), high.tolist()],
                         candidates=candidates, decision='unreviewed; remains opaque'))
    result = dict(walls=rows, unknownCount=len(rows),
                  policy='Bounds overlap only. Verify shape, vertical role and local ground before assigning heights. No runtime mutations.')
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open('x', encoding='utf-8') as output:
        json.dump(result, output, indent=2)
    print(json.dumps(dict(output=str(args.out), unknownCount=len(rows),
                          withCandidates=sum(bool(r['candidates']) for r in rows))))


if __name__ == '__main__':
    main()
