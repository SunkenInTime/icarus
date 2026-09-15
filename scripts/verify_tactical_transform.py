"""Compare transformed casts against piecewise source-space casts independently."""
import argparse
import json
from pathlib import Path
import time
import numpy as np
import shapely
from audit_tactical_target_rays import ReferenceModel
from build_global_tactical_candidate import GroundField


def source_cast(model, field, origin, target):
    line = shapely.LineString([origin[:2], target[:2]])
    candidates = field.tree.query(line, predicate='intersects')
    direction = target[:2] - origin[:2]
    length2 = direction @ direction
    events = [0., 1.]
    for candidate in candidates:
        intersection = line.intersection(field.polygons[candidate])
        for part in shapely.get_parts(intersection):
            for xy in shapely.get_coordinates(part):
                events.append(float(np.clip((xy - origin[:2]) @ direction / length2, 0, 1)))
    events = np.unique(np.round(events, 13))
    relative_z = origin[2]
    for low, high in zip(events, events[1:]):
        if high - low < 1e-11:
            continue
        xy = origin[:2] + np.array([low, high])[:, None] * direction
        # Evaluate the interior cell plane for both endpoints; no boundary
        # tie-breaking can select a different height branch.
        cell = field.locate(xy.mean(0)[None])[0]
        z = xy @ field.planes[cell, :2] + field.planes[cell, 2] + relative_z
        hit = model.cast(np.r_[xy[0], z[0]], np.r_[xy[1], z[1]],
                         min_distance=1e-5 if low == 0 else 0,
                         end_padding=1e-5 if high == 1 else 0)
        if hit is not None:
            hit['sourceRayParameter'] = float((np.array(hit['point'][:2]) - origin[:2]) @ direction / length2)
            return hit
    return None


def verify(source_path, candidate_path, field_path, fixture_path, output):
    source, candidate = ReferenceModel(source_path), ReferenceModel(candidate_path)
    field = GroundField(field_path)
    fixtures = json.loads(fixture_path.read_text())['cases']
    started = time.perf_counter()
    mismatches, samples = [], []
    for case in fixtures:
        query = np.array(case['query'], dtype=float)
        query[2] -= field.heights(query[None, :2])[0]
        for angle in np.linspace(-query[6] / 2 + .01, query[6] / 2 - .01, 11):
            cosine, sine = np.cos(angle), np.sin(angle)
            direction = np.array([query[3] * cosine - query[4] * sine, query[3] * sine + query[4] * cosine])
            target = np.r_[query[:2] + direction * query[5], query[2]]
            expected = source_cast(source, field, query[:3], target)
            actual = candidate.cast(query[:3], target)
            error = None if expected is None or actual is None else float(np.linalg.norm(np.array(expected['point'][:2]) - actual['point'][:2]))
            same = (expected is None) == (actual is None) and (error is None or error < 1e-6)
            sample = dict(case=case['id'], angle=float(angle), expected=expected, actual=actual, hitErrorMeters=error)
            samples.append(sample)
            if not same:
                mismatches.append(sample)
        print(f'{case["id"]}: {len(samples)} rays, {len(mismatches)} mismatches', flush=True)
    report = dict(rays=len(samples), mismatches=len(mismatches), seconds=time.perf_counter() - started,
                  maximumHitErrorMeters=max((s['hitErrorMeters'] or 0 for s in samples), default=0),
                  scope='Equivalence to declared piecewise floor-following source rays, not physical straight-eye rays.',
                  failures=mismatches, samples=samples)
    output.write_text(json.dumps(report, indent=2) + '\n')
    if mismatches:
        raise AssertionError(f'{len(mismatches)} source/candidate ray mismatches')
    print(json.dumps({k: v for k, v in report.items() if k not in ('samples', 'failures')}), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('source', 'candidate', 'field', 'fixtures', 'output'):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    verify(args.source, args.candidate, args.field, args.fixtures, args.output)
