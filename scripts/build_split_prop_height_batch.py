"""Attach measured prop height bounds to existing Split SVG footprints."""
import argparse
import copy
import json
import math
from pathlib import Path

import numpy as np
import shapely

ROOT = Path('E:/IcarusWorldAudit/2026-09-06')
REV = ROOT / 'tactical-visibility-revision'
CONFIGS = [
    ('a-lobby-bench', 'p5-unknown-2', [5945], 6156, 3.0),
    ('b-lobby-photo-booth', 'p9-unknown-3', [6390], 6274, 3.0),
    ('b-garage-crate', 'p11-unknown-0', [6561], 6574, 3.0),
    ('mid-large-statue', 'p18-unknown-0', [3958], 7431, 4.5),
    ('mid-small-statue', 'p19-unknown-0', [3959], 7431, 4.5),
    ('b-garage-tires', 'p20-unknown-0', [1978, 1979], 6574, 3.0),
]


def polygon(row):
    rings = [np.array(r).reshape(-1, 2) for r in row['rings']]
    return shapely.Polygon(rings[0], rings[1:])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(exist_ok=False)
    base = REV / 'split-svg-semantic-prototype-v8'
    models = {s: json.loads((base / f'split-{s}.json').read_text()) for s in ['attack', 'defense']}
    originals = copy.deepcopy(models)
    geometry = ROOT / 'supplemented-v2/world/split/geometry.npz'
    data = np.load(geometry)
    objects = json.loads(geometry.with_suffix('.json').read_text())['objects']
    review = json.loads((base / 'review-poses.json').read_text())
    measurements = []

    def triangles(oid):
        obj = objects[oid]
        ids = np.arange(obj['firstFace'], obj['firstFace'] + obj['faceCount'])
        return ids, data['points'][data['faces'][ids]].astype(float)

    def ground_hits(xy, oid, expected):
        ids, tri = triangles(oid)
        result = []
        for fid, t in zip(ids, tri):
            try:
                uv = np.linalg.solve(np.column_stack((t[1, :2] - t[0, :2], t[2, :2] - t[0, :2])), xy - t[0, :2])
            except np.linalg.LinAlgError:
                continue
            bary = np.r_[1 - uv.sum(), uv]
            z = float(bary @ t[:, 2])
            if bary.min() >= -1e-9 and abs(z - expected) < .05:
                result.append(dict(rawFace=int(fid), nativeXY=xy.tolist(), z=z))
        return result

    for name, attack_id, source_ids, floor_id, expected in CONFIGS:
        mesh = np.concatenate([triangles(i)[1] for i in source_ids])
        center = (mesh[:, :, :2].min((0, 1)) + mesh[:, :, :2].max((0, 1))) / 2
        ground = []
        for delta in [(0, 0), (-.25, 0), (.25, 0), (0, -.25), (0, .25)]:
            hits = ground_hits(center + delta, floor_id, expected)
            assert hits, (name, delta, 'No source floor surface')
            ground.extend(hits)
        floor_range = [min(h['z'] for h in ground), max(h['z'] for h in ground)]
        top = float(mesh[:, :, 2].max())
        height = top - floor_range[0]
        attack = next(w for w in models['attack']['walls'] if w['id'] == attack_id)
        ink = polygon(attack)
        p = np.concatenate([np.array(r).reshape(-1, 2) for r in attack['rings']])
        reflected = np.array([466.1762, 473]) - p
        target_bounds = np.r_[reflected.min(0), reflected.max(0)]
        matches = [w for w in models['defense']['walls'] if w['sourcePathIndex'] == attack['sourcePathIndex']
                   and np.max(abs(np.array(polygon(w).bounds) - target_bounds)) < .002]
        assert len(matches) == 1, name
        evidence = dict(sourceGeometry=str(geometry), sourceObjects=[dict(index=i, **objects[i]) for i in source_ids],
            groundObject=floor_id, groundSamples=ground, groundHeightRangeMeters=floor_range,
            sourceMaximumZ=top, heightUpperBoundMeters=height,
            policy='Conservative full-prop envelope over authored ink. No cosmetic gaps or foliage are used. No standing support inferred from a prop bounding box.')
        ids = {'attack': attack_id, 'defense': matches[0]['id']}
        for side, wid in ids.items():
            wall = next(w for w in models[side]['walls'] if w['id'] == wid)
            assert wall['unknownHeight']
            wall.update(unknownHeight=False, bands=[[0, height]], heightModel='source-measured-cover-upper-bound', heightEvidence=evidence)
            shape = polygon(wall)
            receiver = shapely.union_all([polygon(r) for r in models[side]['receiver']])
            bounds = shape.bounds
            center_svg = np.array([(bounds[0] + bounds[2]) / 2, (bounds[1] + bounds[3]) / 2])
            for dx, dy, label in [(-1, 0, 'west'), (1, 0, 'east'), (0, -1, 'north'), (0, 1, 'south')]:
                extent = (bounds[2] - bounds[0]) / 2 if dx else (bounds[3] - bounds[1]) / 2
                origin = center_svg + np.array([dx, dy]) * (extent + 3)
                point = shapely.Point(origin)
                occupied = [polygon(w).envelope for w in models[side]['walls']
                    if w.get('heightModel', '').startswith('source-measured-cover')]
                occupied.extend(polygon(s) for s in models[side]['supports'])
                if (not receiver.covers(point)
                        or any(polygon(w).covers(point) for w in models[side]['walls'])
                        or any(region.covers(point) for region in occupied)):
                    continue
                delta = center_svg - origin
                review['cases'].append(dict(id=f'{name}-{label}-{side}', side=side, originSvg=origin.tolist(),
                    directionRadians=math.atan2(delta[1], delta[0]), rangeSvg=60,
                    apertureRadians=math.radians(103), description=f'Ground sightline across {name} and surrounding SVG walls.'))
        measurements.append(dict(id=name, wallsBySide=ids, **evidence))
    for side, model in models.items():
        changed = {r['wallsBySide'][side] for r in measurements}
        for before, after in zip(originals[side]['walls'], model['walls']):
            assert before['rings'] == after['rings']
            if before['id'] not in changed:
                assert before == after
        assert originals[side]['supports'] == model['supports']
        (args.out / f'split-{side}.json').write_text(json.dumps(model, separators=(',', ':')))
    (args.out / 'review-poses.json').write_text(json.dumps(review))
    (args.out / 'prop-height-batch.json').write_text(json.dumps(measurements, indent=2))
    for name in ['source-height-evidence.json', 'annotation-extension.json', 'floor-transition-corrections.json']:
        (args.out / name).write_bytes((base / name).read_bytes())
    print(json.dumps([dict(id=m['id'], height=m['heightUpperBoundMeters']) for m in measurements]))


if __name__ == '__main__':
    main()
