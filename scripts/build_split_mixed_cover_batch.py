"""Separate heights at authored shared edges while preserving the union of ink."""
import argparse
import copy
import json
import math
from pathlib import Path
import xml.etree.ElementTree as ET

import numpy as np
import shapely

ROOT = Path('E:/IcarusWorldAudit/2026-09-06')
REV = ROOT / 'tactical-visibility-revision'
CONFIGS = [
    dict(id='a-lobby-pallet-and-crate', wall='p5-unknown-0', axis=0,
         shared=[310.972, 155.204], highGreater=True, low=[1052, 1053, 1054], high=[5952], floor=6155, expectedFloor=3.),
    dict(id='a-ramp-metal-and-crate', wall='p7-unknown-1', axis=1,
         shared=[210.45, 262.55], highGreater=True, low=[5951], high=[520], floor=5923, expectedFloor=6.5),
    dict(id='a-tower-low-and-high-crate', wall='p8-unknown-0', axis=1,
         shared=[148.781, 324.219], highGreater=False, low=[5897], high=[519], floor=5930, expectedFloor=6.5),
    dict(id='b-fridge-and-barrel', wall='p9-unknown-0', axis=1,
         shared=[113.693, 359.307], highGreater=False, low=[1817], high=[6664], floor=6712, expectedFloor=3.),
]


def poly(w):
    rings = [np.array(r).reshape(-1, 2) for r in w['rings']]
    return shapely.Polygon(rings[0], rings[1:])


def rings(p):
    return [np.array(r.coords).reshape(-1).tolist() for r in [p.exterior, *p.interiors]]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(exist_ok=False)
    base = REV / 'split-svg-semantic-prototype-v10'
    models = {s: json.loads((base / f'split-{s}.json').read_text()) for s in ['attack', 'defense']}
    old = copy.deepcopy(models)
    gp = ROOT / 'supplemented-v2/world/split/geometry.npz'
    data = np.load(gp)
    meta = json.loads(gp.with_suffix('.json').read_text())['objects']
    elements = {s: list(ET.parse(Path('assets/maps') / f).getroot())
                for s, f in [('attack', 'split_map.svg'), ('defense', 'split_map_defense.svg')]}

    def tris(oid):
        o = meta[oid]
        ids = np.arange(o['firstFace'], o['firstFace'] + o['faceCount'])
        return ids, data['points'][data['faces'][ids]].astype(float)

    def height(ids, floor, expected):
        mesh = np.concatenate([tris(i)[1] for i in ids])
        xy = (mesh[:, :, :2].min((0, 1)) + mesh[:, :, :2].max((0, 1))) / 2
        ground = []
        for delta in [(0, 0), (-.2, 0), (.2, 0), (0, -.2), (0, .2)]:
            point = xy + delta
            for fid, t in zip(*tris(floor)):
                try:
                    uv = np.linalg.solve(np.column_stack((t[1, :2] - t[0, :2], t[2, :2] - t[0, :2])), point - t[0, :2])
                except np.linalg.LinAlgError:
                    continue
                b = np.r_[1 - uv.sum(), uv]
                z = float(b @ t[:, 2])
                if b.min() >= -1e-9 and abs(z - expected) < .05:
                    ground.append(dict(rawFace=int(fid), nativeXY=point.tolist(), z=z))
        assert len(ground) >= 5, ids
        top = float(mesh[:, :, 2].max())
        bound = top - min(g['z'] for g in ground)
        return bound, dict(sourceObjects=[dict(index=i, **meta[i]) for i in ids],
                          sourceGeometry=str(gp), groundObject=floor, groundSamples=ground,
                          maximumSourceZ=top, heightUpperBoundMeters=bound)

    reports = []
    for cfg in CONFIGS:
        attack = next(w for w in old['attack']['walls'] if w['id'] == cfg['wall'])
        p = np.concatenate([np.array(r).reshape(-1, 2) for r in attack['rings']])
        mirror = np.array([466.1762, 473]) - p
        bounds = np.r_[mirror.min(0), mirror.max(0)]
        matches = [w for w in old['defense']['walls'] if w['sourcePathIndex'] == attack['sourcePathIndex']
                   and np.max(abs(np.array(poly(w).bounds) - bounds)) < .002]
        assert len(matches) == 1
        measured = {role: height(cfg[role], cfg['floor'], cfg['expectedFloor']) for role in ['low', 'high']}
        assert measured['low'][0] < 1.75 < measured['high'][0]
        report = dict(id=cfg['id'], sourceMeasurements={k: v[1] for k, v in measured.items()}, sides={})
        for si, (side, original) in enumerate([('attack', attack), ('defense', matches[0])]):
            assert original['unknownHeight']
            shape = poly(original)
            width = float(elements[side][original['sourcePathIndex']].get('stroke-width', '1'))
            greater = cfg['highGreater'] if side == 'attack' else not cfg['highGreater']
            # The whole painted shared wall belongs to the taller neighbour.
            # Split at its low-facing painted edge, using the actual stroke width.
            cut = cfg['shared'][si] + (-width / 2 if greater else width / 2)
            axis = cfg['axis']
            low_rect = shapely.box(-1000, -1000, cut if axis == 0 else 1000, cut if axis == 1 else 1000)
            high_rect = shapely.box(cut if axis == 0 else -1000, cut if axis == 1 else -1000, 1000, 1000)
            masks = {'low': low_rect if greater else high_rect, 'high': high_rect if greater else low_rect}
            pieces = []
            for role, mask in masks.items():
                for index, part in enumerate(shapely.get_parts(shape.intersection(mask))):
                    if not isinstance(part, shapely.Polygon) or part.area == 0:
                        continue
                    record = copy.deepcopy(original)
                    record.update(id=f'{original["id"]}-{role}-{index}', parentWallId=original['id'],
                                  rings=rings(part), bands=[[0, measured[role][0]]], unknownHeight=False,
                                  heightModel='source-measured-cover-upper-bound', heightEvidence=measured[role][1])
                    pieces.append(record)
            assert len(pieces) >= 2
            union = shapely.union_all([poly(p) for p in pieces])
            assert shape.symmetric_difference(union).area < 1e-9
            models[side]['walls'] = [w for w in models[side]['walls'] if w['id'] != original['id']] + pieces
            report['sides'][side] = dict(parentWallId=original['id'], pieceIds=[p['id'] for p in pieces],
                axis=axis, sharedCenter=cfg['shared'][si], strokeWidth=width, splitAtPaintedEdge=cut,
                highGreater=greater, bounds=list(shape.bounds), unionDifferenceSvg2=shape.symmetric_difference(union).area)
        reports.append(report)
    for side, model in models.items():
        removed = {r['sides'][side]['parentWallId'] for r in reports}
        for w in old[side]['walls']:
            if w['id'] not in removed:
                assert next(q for q in model['walls'] if q['id'] == w['id']) == w
        assert model['receiver'] == old[side]['receiver'] and model['supports'] == old[side]['supports']
        (args.out / f'split-{side}.json').write_text(json.dumps(model, separators=(',', ':')))
    review = json.loads((base / 'review-poses.json').read_text())
    for report in reports:
        for side in ['attack', 'defense']:
            info = report['sides'][side]
            axis, bounds = info['axis'], info['bounds']
            receiver = shapely.union_all([poly(r) for r in models[side]['receiver']])
            centers = {}
            for role in ['low', 'high']:
                shapes = [poly(w) for w in models[side]['walls']
                          if w['id'] in info['pieceIds'] and f'-{role}-' in w['id']]
                b = shapely.union_all(shapes).bounds
                centers[role] = np.array([(b[0] + b[2]) / 2, (b[1] + b[3]) / 2])
                cross = 1 - axis
                origin = centers[role].copy()
                choices = [bounds[cross + 2] + 3, bounds[cross] - 3]
                if side == 'defense':
                    choices.reverse()
                for coordinate in choices:
                    origin[cross] = coordinate
                    if receiver.covers(shapely.Point(origin)):
                        break
                else:
                    raise AssertionError((report['id'], side, role, 'No ground approach within SVG'))
                delta = centers[role] - origin
                review['cases'].append(dict(id=f'{report["id"]}-{role}-{side}', side=side,
                    originSvg=origin.tolist(), directionRadians=math.atan2(delta[1], delta[0]),
                    rangeSvg=65, apertureRadians=math.radians(103), description=f'Approach the {role} member of joined cover.'))
            origin = centers['low'].copy()
            origin[axis] = bounds[axis] - 3 if info['highGreater'] else bounds[axis + 2] + 3
            assert receiver.covers(shapely.Point(origin))
            delta = np.zeros(2)
            delta[axis] = 1 if info['highGreater'] else -1
            review['cases'].append(dict(id=f'{report["id"]}-shared-{side}', side=side,
                originSvg=origin.tolist(), directionRadians=math.atan2(delta[1], delta[0]),
                rangeSvg=65, apertureRadians=math.radians(103), description='Look across low cover toward the taller neighbour.'))
    (args.out / 'review-poses.json').write_text(json.dumps(review))
    for name in ['source-height-evidence.json', 'annotation-extension.json', 'floor-transition-corrections.json', 'prop-height-batch.json']:
        (args.out / name).write_bytes((base / name).read_bytes())
    (args.out / 'mixed-cover-batch.json').write_text(json.dumps(reports, indent=2))
    print(json.dumps([{r['id']: {role: value['heightUpperBoundMeters'] for role, value in r['sourceMeasurements'].items()}} for r in reports]))


if __name__ == '__main__':
    main()
