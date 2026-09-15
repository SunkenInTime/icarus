"""Source-backed floor policy checks against frozen problem rays.

This reuses the diagnostic support export and original source BVH. It does not
change the app or certify game visibility merely from a longer ray.
"""
import argparse
import hashlib
import json
from pathlib import Path
import numpy as np
import shapely
from audit_tactical_target_rays import ReferenceModel
from probe_source_floor_support import SourceSupport


def load_support(revision, name, all_walkable=False):
    directory = revision / ('source-floor-support-all-walkable-v1' if all_walkable else 'source-floor-support-union-v6')
    metadata = json.loads((directory / f'{name}.floor-support.json').read_text())
    path = directory / metadata['dataFile']
    if hashlib.sha256(path.read_bytes()).hexdigest() != metadata['dataSha256']:
        raise ValueError('Support export changed')
    arrays = np.load(path)
    support = SourceSupport.__new__(SourceSupport)
    support.points = arrays['vertices'][arrays['triangles']]
    support.source_ids = arrays['sourceFaces']
    support.navigation_indices = arrays['navigationIndices']
    support.detailed_navigation_indices = arrays['detailedNavigationIndices']
    row = next(row for row in json.loads((revision.parent / 'completeness/combined-manifest-release-inputs-v2.json').read_text()) if row['map'] == name)
    objects = json.loads((Path(row['combinedWorldFolder']) / 'geometry.json').read_text())['objects']
    original = np.load(revision / 'full-height-input-v1' / name / 'source-correspondence.npz')['sourceFaces']
    starts = np.array([o['firstFace'] for o in objects])
    support.objects = [objects[np.searchsorted(starts, original[i], side='right') - 1]['path'] if i >= 0 else 'Navigation support' for i in support.source_ids]
    support.planes = np.linalg.solve(np.concatenate([support.points[:, :, :2], np.ones((len(support.points), 3, 1))], axis=2), support.points[:, :, 2, None])[:, :, 0]
    support.polygons = shapely.polygons(support.points[:, :, :2])
    support.original_polygons = support.polygons.copy()
    extension = arrays['extensionMeters']
    extended = extension > 0
    support.polygons[extended] = shapely.buffer(support.polygons[extended], extension[extended])
    support.tree = shapely.STRtree(support.polygons)
    return support


def source_model(revision, name, native=False):
    path = revision / 'full-height-input-v1' / name / f'{name}.height.bin.gz'
    if native:
        from native_reference_cast import NativeReferenceModel
        return NativeReferenceModel(path, revision / 'native-tactical-rays-build/Release/tactical_reference_cast.dll')
    return ReferenceModel(path)


def step_height(revision, name, bounded):
    if not bounded:
        return None
    data = json.loads((revision.parent / 'nav/baked' / f'{name}_navigation.json').read_text())
    return float(data['source']['walkableClimbCm']) / 100


def report_directory(revision, bounded, detached=False, all_walkable=False):
    directory = revision / ('source-floor-support-all-walkable-detached-v3' if all_walkable else 'source-floor-support-nav-guided-detached-v3' if detached else 'source-floor-support-nav-guided-bounded-v1' if bounded else 'source-floor-support-nav-guided-v1')
    directory.mkdir(exist_ok=True)
    return directory


def probe(revision, name, continuity=False, native=False, bounded=False, detached=False, all_walkable=False):
    support = load_support(revision, name, all_walkable)
    source = source_model(revision, name, native)
    maximum_step = step_height(revision, name, bounded)
    fixtures = json.loads((revision / 'gallery-all-map-lower-provisional-v1' / f'{name}-fixtures.json').read_text())['cases']
    if name == 'fracture':
        fixtures = [row for row in fixtures if 'overlap' in row['id']]
        for label, origin, index in [('north-worst-portal', [104.90183333333333, 39.62116666666666, 6.75], 31),
                                      ('south-worst-portal', [73.48316666666666, -40.82916666666667, 7.2501], 61)]:
            fixtures.append(dict(id=label, query=origin + [np.cos(index * 2 * np.pi / 64), np.sin(index * 2 * np.pi / 64), 65, 0]))
    elif name == 'icebox':
        fixtures = [row for row in fixtures if row['id'] in ('icebox-ramp-1-forward', 'icebox-ramp-2-reverse') or row['id'] in ('ramp-1-forward', 'ramp-2-reverse')]
        fixtures.append(dict(id='snowman-overpaint', query=[29.26115246, -35.21712548, 2.75528251, 1, 0, .05, 0]))
    results = []
    for fixture in fixtures:
        q = fixture['query']; samples = []
        offsets = [(0, 0), (.01, 0), (-.01, 0)] if continuity else [(0, 0)]
        angles = np.arange(360) * np.pi / 180 if continuity else [np.arctan2(q[4], q[3])]
        for offset in offsets:
            origin = np.array(q[:3]) + [*offset, 0]
            for angle in angles:
                result = support.cast(source, origin, [np.cos(angle), np.sin(angle)], q[5], True, True, True,
                                      maximum_step, detached)
                result.update(origin=origin.tolist(), angleRadians=float(angle), offset=offset)
                samples.append(result)
            if continuity:
                print(fixture['id'], 'completed origin offset', offset, flush=True)
        results.append(dict(id=fixture['id'], query=q, samples=samples))
        print(fixture['id'], 'rays', len(samples), 'hits', [round(sample['distanceMeters'], 5) for sample in samples[:3]], flush=True)
        target = report_directory(revision, bounded, detached, all_walkable) / f'{name}-{"continuity" if continuity else "regressions"}.json'
        target.write_text(json.dumps(dict(map=name, scope=__doc__, cases=results), indent=2) + '\n')
    target = report_directory(revision, bounded, detached, all_walkable) / f'{name}-{"continuity" if continuity else "regressions"}.json'
    target.write_text(json.dumps(dict(map=name, scope=__doc__, cases=results), indent=2) + '\n')


def probe_lost(revision, name, native=False, bounded=False, detached=False, all_walkable=False):
    support = load_support(revision, name, all_walkable)
    source = source_model(revision, name, native)
    maximum_step = step_height(revision, name, bounded)
    fixtures = json.loads((revision / 'gallery-all-map-lower-provisional-v1' / f'{name}-lost-source-directions.json').read_text())['cases']
    results = []
    for fixture in fixtures:
        q = fixture['query']; samples = []
        for ray in fixture['lostDirections']:
            result = support.cast(source, q[:3], ray['direction'][:2], q[5], True, True, True, maximum_step, detached)
            result.update(directionIndex=ray['directionIndex'], beforeDistanceMeters=ray['beforeDistanceMeters'],
                          previousDistanceMeters=ray['afterDistanceMeters'])
            samples.append(result)
        results.append(dict(id=fixture['id'], query=q, samples=samples))
        print(fixture['id'], 'rays', len(samples), 'gained>1m', sum(s['distanceMeters'] - s['previousDistanceMeters'] > 1 for s in samples),
              'lost>1m', sum(s['previousDistanceMeters'] - s['distanceMeters'] > 1 for s in samples), flush=True)
        target = report_directory(revision, bounded, detached, all_walkable) / f'{name}-lost-regressions.json'
        target.write_text(json.dumps(dict(map=name, scope=__doc__, cases=results), indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('revision', type=Path)
    parser.add_argument('map')
    parser.add_argument('--continuity', action='store_true')
    parser.add_argument('--lost', action='store_true')
    parser.add_argument('--native', action='store_true')
    parser.add_argument('--bounded-step', action='store_true')
    parser.add_argument('--detached-gap', action='store_true')
    parser.add_argument('--all-walkable', action='store_true')
    args = parser.parse_args()
    if args.detached_gap and not args.bounded_step:
        parser.error('Detached gap policy requires bounded native step height')
    if args.all_walkable and not args.detached_gap:
        parser.error('All-walkable regression scope requires the detached policy')
    if args.lost:
        probe_lost(args.revision, args.map, args.native, args.bounded_step, args.detached_gap, args.all_walkable)
    else:
        probe(args.revision, args.map, args.continuity, args.native, args.bounded_step, args.detached_gap, args.all_walkable)
