"""Diagnostic source rays that follow a continuous local floor branch.

This is an experimental tactical policy, not a production representation.
At a fork whose floor heights coincide, prefer the continuation with the least
height change. Switching between separated floors is forbidden.
"""
import argparse
import json
from pathlib import Path
import numpy as np
import shapely
from build_global_tactical_candidate import GroundField
from audit_tactical_target_rays import ReferenceModel


def cast(source, fields, world_origin, direction, distance, standing_height=1.75):
    origin = np.array(world_origin, dtype=float)
    direction = np.array(direction, dtype=float)
    direction /= np.linalg.norm(direction)
    vector = direction * distance
    line = shapely.LineString([origin[:2], origin[:2] + vector])
    first = fields[0]
    events = [0., 1.]
    for cell in first.tree.query(line, predicate='intersects'):
        for xy in shapely.get_coordinates(line.intersection(first.polygons[cell])):
            events.append(float(np.clip((xy - origin[:2]) @ vector / (distance * distance), 0, 1)))
    events = np.unique(np.round(events, 13))
    heights = np.array([field.heights(origin[None, :2])[0] for field in fields])
    floor = origin[2] - standing_height
    closest = np.min(abs(heights - floor))
    allowed = np.flatnonzero(abs(abs(heights - floor) - closest) < 1e-6)
    selected = int(allowed[0])
    previous_height = float(heights[selected])
    relative_eye = float(origin[2] - previous_height)
    pieces = []
    for lo, hi in zip(events, events[1:]):
        if hi - lo < 1e-11:
            continue
        xy = origin[:2] + np.array([lo, hi])[:, None] * vector
        cell = first.locate(xy.mean(0)[None])[0]
        candidates = np.array([xy @ field.planes[cell, :2] + field.planes[cell, 2] for field in fields])
        if lo == 0:
            admitted = allowed
        else:
            admitted = np.flatnonzero(abs(candidates[:, 0] - previous_height) < 1e-6)
        if not len(admitted):
            raise ValueError('No continuous branch at ray boundary')
        changes = abs(candidates[admitted, 1] - previous_height)
        selected = int(admitted[np.argmin(changes)])
        ground = candidates[selected]
        z = ground + relative_eye
        hit = source.cast(np.r_[xy[0], z[0]], np.r_[xy[1], z[1]],
                          min_distance=1e-5 if lo == 0 else 0, end_padding=1e-5 if hi == 1 else 0)
        pieces.append(dict(start=lo * distance, end=hi * distance, chart=selected,
                           ground=ground.tolist(), joinErrorMeters=abs(float(ground[0] - previous_height))))
        previous_height = float(ground[1])
        if hit is not None:
            return dict(hit=hit, distanceMeters=float((np.array(hit['point'][:2]) - origin[:2]) @ direction), pieces=pieces)
    return dict(hit=None, distanceMeters=distance, pieces=pieces)


def probe(revision, name):
    folder = revision / 'local-ground-charts-v1' / name
    manifest = json.loads((folder / 'manifest.json').read_text())
    # Independent regions never require a Cartesian product of runtime packs:
    # a ray chooses its floor branch locally in each shared XY cell.
    fields = [GroundField(manifest['charts'][i]['field']) for i in (0, -1)]
    source = ReferenceModel(revision / 'full-height-input-v1' / name / f'{name}.height.bin.gz')
    cases = json.loads((revision / 'gallery-all-map-lower-provisional-v1' / f'{name}-fixtures.json').read_text())['cases']
    if name == 'fracture':
        cases += [dict(id='north-worst-portal', query=[104.90183333333333, 39.62116666666666, 6.75,
                                                     np.cos(31 * 2 * np.pi / 64), np.sin(31 * 2 * np.pi / 64), 65, 0]),
                  dict(id='south-worst-portal', query=[73.48316666666666, -40.82916666666667, 7.2501,
                                                     np.cos(61 * 2 * np.pi / 64), np.sin(61 * 2 * np.pi / 64), 65, 0])]
    results = []
    for case in cases:
        q = case['query']; samples = []
        for angle in np.linspace(-q[6] / 2 + .001, q[6] / 2 - .001, 11) if q[6] else [0]:
            dx = q[3] * np.cos(angle) - q[4] * np.sin(angle)
            dy = q[3] * np.sin(angle) + q[4] * np.cos(angle)
            row = cast(source, fields, q[:3], [dx, dy], q[5])
            row['angle'] = float(angle); samples.append(row)
        results.append(dict(id=case['id'], query=q, samples=samples))
        print(case['id'], [(round(s['distanceMeters'], 3), s['hit']['normal'] if s['hit'] else None) for s in samples], flush=True)
    (folder / 'ray-local-probe.json').write_text(json.dumps(dict(map=name, policy=__doc__, cases=results), indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('revision', type=Path)
    parser.add_argument('map')
    args = parser.parse_args()
    probe(args.revision, args.map)
