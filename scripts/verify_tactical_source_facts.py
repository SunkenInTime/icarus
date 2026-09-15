"""Check frozen physical facts against a floor-relative candidate.

These checks do not require every original horizontal ray to survive flattening.
They retain low-cover clearance, nearby opaque walls, and surfaces separating
overlapping observer floors. Source fixture answers are never regenerated here.
"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np

from audit_tactical_target_rays import ReferenceModel
from build_global_tactical_candidate import GroundField
from tactical_alignment_candidate import Warp
from tactical_alignment_warps import load_warp


def verify(fixtures, pack, field_path, output, projection_path=None, warp_path=None, ground_warped=False):
    data = json.loads(fixtures.read_text())
    model = ReferenceModel(pack)
    name = model.header['map']
    ground = GroundField(field_path)
    if warp_path and not projection_path:
        raise ValueError('An explicit XY warp requires its native-to-SVG projection.')
    if ground_warped and not warp_path:
        raise ValueError('A composed ground field requires an explicit XY warp.')
    if projection_path and not warp_path and name != 'split':
        raise ValueError('The optional Warp is Split-specific; another map needs its own explicit warp implementation.')
    warp = load_warp(warp_path) if warp_path else Warp() if projection_path else None
    projection = None
    if projection_path:
        projection = np.asarray(json.loads(projection_path.read_text())['nativeToAttackSvg'])

    def transform(point):
        result = np.asarray(point, dtype=float).copy()
        if not ground_warped:
            result[2] -= ground.heights(result[None, :2])[0]
        if warp:
            svg = projection[:, :2] @ result[:2] + projection[:, 2]
            warped = warp.apply(svg[None])[0]
            result[:2] = np.linalg.solve(projection[:, :2], warped - projection[:, 2])
        if ground_warped:
            result[2] -= ground.heights(result[None, :2])[0]
        return result

    checks = []
    def check(label, reference, expected_blocked, target=None, exact_vertical=False):
        origin = transform(reference['origin'])
        endpoint = transform(reference['target'] if target is None else target)
        hit = model.cast(origin, endpoint)
        passed = (hit is not None) == expected_blocked
        error = None
        if exact_vertical and hit is not None:
            expected_point = transform(reference['hit']['point'])
            error = float(np.linalg.norm(np.asarray(hit['point']) - expected_point))
            passed &= error <= .005
        checks.append({'id': label, 'expectedBlocked': expected_blocked,
                       'actualBlocked': hit is not None, 'passed': bool(passed),
                       'origin': origin.tolist(), 'target': endpoint.tolist(),
                       'hit': hit, 'verticalHitErrorMeters': error})

    for row in [*data['lowCoverCases'], *data.get('opaqueCornerCases', [])]:
        if row['map'] != name:
            continue
        if 'clearTargetBeforeWall' in row:
            check(row['id'] + '-clears-low-crate', row['clearTargetBeforeWall'], False)
        ray = row['modelRay']
        if ray['blocked']:
            a, b = np.asarray(ray['origin']), np.asarray(ray['target'])
            unit = (b - a) / np.linalg.norm(b - a)
            # Stop shortly behind the known wall, not across remote floors.
            target = a + unit * (ray['hit']['distanceMeters'] + .05)
            check(row['id'] + '-nearby-opaque-wall', ray, True, target)
    for row in data['overlapCases']:
        if row['map'] != name:
            continue
        reference = row['verticalBetweenStandingEyes']
        assert reference['blocked'], 'Frozen overlapping floors require a separating source surface.'
        check(row['id'] + '-separate-floors', reference, True, exact_vertical=True)
        lower = transform(reference['origin'])
        upper = transform(reference['target'])
        difference = row['floorMeters'][1] - row['floorMeters'][0]
        checks.append({'id': row['id'] + '-eye-height-separation',
                       'passed': abs((upper[2] - lower[2]) - difference) < 1e-9,
                       'expectedSeparationMeters': difference,
                       'actualSeparationMeters': float(upper[2] - lower[2])})
    report = {'map': name, 'status': 'passed' if checks and all(r['passed'] for r in checks) else 'failed',
              'scope': 'Frozen source facts, not complete gameplay or all-ray equivalence. Camera fit remains uncertain. Ground subtraction uses the declared original or registered XY field; exact warp and asset hashes are recorded.',
              'fixtureSha256': hashlib.sha256(fixtures.read_bytes()).hexdigest(),
              'candidatePackSha256': hashlib.sha256(pack.read_bytes()).hexdigest(),
              'groundSha256': hashlib.sha256(field_path.read_bytes()).hexdigest(),
              'warpSha256': hashlib.sha256(warp_path.read_bytes()).hexdigest() if warp_path else None,
              'groundCoordinateSpace': 'registered-XY' if ground_warped else 'original-XY', 'checks': checks}
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + '\n')
    print(f"{name}: {sum(c['passed'] for c in checks)}/{len(checks)} source-fact checks passed")
    if report['status'] != 'passed':
        raise SystemExit(1)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('fixtures', type=Path)
    parser.add_argument('pack', type=Path)
    parser.add_argument('ground', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--projection', type=Path, help='Enables the isolated Split XY warp after ground subtraction.')
    parser.add_argument('--warp', type=Path, help='Exact declared local registration NPZ.')
    parser.add_argument('--ground-warped', action='store_true', help='Ground field is already composed into registered XY.')
    args = parser.parse_args()
    verify(args.fixtures, args.pack, args.ground, args.output, args.projection, args.warp, args.ground_warped)
