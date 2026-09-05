"""Find height-sensitive 3D rays that Icarus still clips nearby.

This ranks investigation fixtures, not confirmed gameplay defects. It uses
the recorded production comparison and refuses mismatched evidence files.
"""
import argparse
import hashlib
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('rays')
    parser.add_argument('comparison')
    parser.add_argument('output')
    parser.add_argument('--object-name', default='', help='Optional source-name filter; not a material classification.')
    parser.add_argument('--minimum-difference', type=float, default=2)
    args = parser.parse_args()
    if args.minimum_difference <= 0:
        parser.error('--minimum-difference must be positive')
    raw = Path(args.rays).read_bytes()
    world = json.loads(raw)
    comparison = json.loads(Path(args.comparison).read_text(encoding='utf-8'))
    fingerprint = hashlib.sha256(raw).hexdigest()
    if comparison['fingerprints'].get(comparison['referenceFile']) != fingerprint:
        raise ValueError('The comparison was generated from a different ray report.')
    runtime = {r['id']: r for r in comparison['rays']}
    groups = {}
    for ray in world['rays']:
        parts = ray['id'].split('-')
        if len(parts) == 3 and parts[0].isdigit():
            groups.setdefault((parts[0], parts[2]), []).append(ray)
    candidates = []
    for rays in groups.values():
        low, high = min(rays, key=lambda r: r['heightAboveFloorMeters']), max(rays, key=lambda r: r['heightAboveFloorMeters'])
        if low['objectIndex'] is None or high['heightAboveFloorMeters'] <= low['heightAboveFloorMeters']:
            continue
        if any(abs(low[p][i] - high[p][i]) > 1e-5 for p in ['startMeters', 'endMeters'] for i in [0, 1]):
            raise ValueError('Height-paired rays do not share a horizontal path.')
        comp = runtime[high['id']]
        if not comp['insideRuntimeFootprint'] or low['originNearSurface'] or high['originNearSurface']:
            continue
        owner = world['objects'][low['objectIndex']]
        if args.object_name.lower() not in owner['path'].lower():
            continue
        if (high['distanceMeters'] - low['distanceMeters'] < args.minimum_difference or
                high['distanceMeters'] - comp['runtimeDistanceMeters'] < args.minimum_difference):
            continue
        candidates.append({'low': low, 'high': high, 'object': owner, 'runtimeHigh': comp})
    candidates.sort(key=lambda c: c['high']['distanceMeters'] - c['runtimeHigh']['runtimeDistanceMeters'], reverse=True)
    result = {
        'schemaVersion': 1, 'status': 'geometry-candidates', 'gameplayVerified': False,
        'raysSha256': fingerprint,
        'comparisonSha256': hashlib.sha256(Path(args.comparison).read_bytes()).hexdigest(),
        'minimumDifferenceMeters': args.minimum_difference, 'objectNameFilter': args.object_name,
        'count': len(candidates),
        'blockingObjectPlacements': len({c['low']['objectIndex'] for c in candidates}),
        'candidates': candidates,
        'limitations': ['Test heights are not verified camera heights.',
                        'Floor accessibility, registration, active state and opacity still need validation.'],
    }
    Path(args.output).write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps({k: v for k, v in result.items() if k != 'candidates'}))


if __name__ == '__main__':
    main()
