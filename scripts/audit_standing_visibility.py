"""Rank standing visibility differences using height stability and source materials.

The output proposes investigations, not automatic collision edits. Every ray
keeps the original source and production-comparison fingerprints.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path


def hits_back_face(ray):
    normal = ray.get('normal')
    if normal is None:
        return False
    delta = [b - a for a, b in zip(ray['startMeters'], ray['endMeters'])]
    return sum(n * d for n, d in zip(normal, delta)) > 0.00001


def audit(world_path, comparison_path, output, tolerance=0.25, stability=0.05):
    raw = Path(world_path).read_bytes()
    world = json.loads(raw)
    comparison = json.loads(Path(comparison_path).read_text(encoding='utf-8'))
    if comparison['fingerprints'].get(comparison['referenceFile']) != hashlib.sha256(raw).hexdigest():
        raise ValueError('Comparison and world rays have different fingerprints.')
    if len(world['eyeHeightCandidatesMeters']) < 2:
        raise ValueError('Height stability requires at least two standing-height candidates.')
    runtime = {r['id']: r for r in comparison['rays']}
    floors = {f['sample']: f for f in world['floorChecks']}
    groups = {}
    for ray in world['rays']:
        parts = ray['id'].split('-')
        if len(parts) == 3 and parts[0].isdigit():
            groups.setdefault((int(parts[0]), int(parts[2])), []).append(ray)
    rows = []
    for (sample, direction), rays in groups.items():
        rays.sort(key=lambda r: r['heightAboveFloorMeters'])
        if [r['heightAboveFloorMeters'] for r in rays] != world['eyeHeightCandidatesMeters']:
            raise ValueError('Incomplete height group.')
        current = [runtime[r['id']] for r in rays]
        reference = [r['distanceMeters'] for r in rays]
        differences = {key: max(abs(c[key] - ref) for c, ref in zip(current, reference))
                       for key in ['runtimeDistanceMeters', 'rawSourceDistanceMeters', 'rawSourceAtFloorDistanceMeters']}
        if not all(c['insideRuntimeFootprint'] for c in current):
            status = 'outside-current-footprint'
        elif any(r['originNearSurface'] for r in rays):
            status = 'origin-near-surface'
        elif floors[sample]['materialCategory'] != 'opaque' or any(r['materialCategory'] != 'opaque' for r in rays):
            status = 'uncertain-reference-material-or-no-hit'
        elif any(hits_back_face(r) for r in rays):
            status = 'back-facing-reference'
        elif max(reference) - min(reference) > stability or len({r['objectIndex'] for r in rays}) != 1:
            status = 'height-sensitive-reference'
        elif differences['runtimeDistanceMeters'] <= tolerance:
            status = 'current-matches-reference'
        elif differences['rawSourceDistanceMeters'] <= tolerance:
            status = 'raw-eye-layer-candidate'
        elif differences['rawSourceAtFloorDistanceMeters'] <= tolerance:
            status = 'raw-floor-layer-candidate'
        else:
            status = 'unexplained-difference'
        rows.append({'sample': sample, 'direction': direction, 'status': status,
                     'rayIds': [r['id'] for r in rays],
                     'originWorldXY': rays[0]['startMeters'][:2],
                     'floorWorldZ': floors[sample]['hitMeters'][2],
                     'referenceDistancesMeters': reference,
                     'runtimeDistancesMeters': [c['runtimeDistanceMeters'] for c in current],
                     'rawEyeDistancesMeters': [c['rawSourceDistanceMeters'] for c in current],
                     'rawFloorDistancesMeters': [c['rawSourceAtFloorDistanceMeters'] for c in current],
                     'maximumDifferencesMeters': differences,
                     'blockingObjects': sorted({world['objects'][r['objectIndex']]['path'] for r in rays if r['objectIndex'] is not None})})
    rows.sort(key=lambda r: r['maximumDifferencesMeters']['runtimeDistanceMeters'], reverse=True)
    result = {'schemaVersion': 1, 'map': world['map'], 'status': 'standing-reference-triage',
              'gameplayCertified': False, 'productionEdits': False,
              'eyeHeightCandidatesMeters': world['eyeHeightCandidatesMeters'],
              'distanceToleranceMeters': tolerance, 'heightStabilityMeters': stability,
              'worldRaysSha256': hashlib.sha256(raw).hexdigest(),
              'comparisonSha256': hashlib.sha256(Path(comparison_path).read_bytes()).hexdigest(),
              'summary': dict(Counter(r['status'] for r in rows)), 'groups': rows,
              'limitations': ['Parsed opacity and selected art are not complete runtime-state validation.',
                              'Back-facing first hits require winding, two-sided material and origin review.',
                              'Height candidates are not certified game camera defaults.',
                              'Registration, omitted levels and observer-floor accessibility still require validation.',
                              'Candidate counts are not an accuracy score.']}
    Path(output).write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps(result['summary']))
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('world')
    parser.add_argument('comparison')
    parser.add_argument('output')
    args = parser.parse_args()
    audit(args.world, args.comparison, args.output)
