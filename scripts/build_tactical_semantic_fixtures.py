"""Freeze source-backed low-cover and overlapping-floor regression cases.

Live captures identify the Split landmark, not an exact horizontal camera pose.
The ray answers here are independently recast source triangles, never game truth.
"""
import argparse
import gzip
import hashlib
import json
import math
from pathlib import Path

import numpy as np

from audit_tactical_target_rays import ReferenceModel


def fingerprint(path):
    return {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def floor_triangles(nav, transform, detailed=True):
    mesh = nav['floorMesh'] if detailed else nav
    v = np.asarray(mesh['vertices'], dtype=float).reshape(-1, 3)
    uv = v[:, :2] / mesh['coordinateScale']
    v[:, 0] = (uv[:, 1] - transform['YScalarToAdd']) / (100 * transform['YMultiplier'])
    v[:, 1] = -(uv[:, 0] - transform['XScalarToAdd']) / (100 * transform['XMultiplier'])
    v[:, 2] /= 100
    if not detailed:
        v[:, 2] = np.asarray(nav['refinedFloorHeightsCm']) / 100
    indices = np.asarray(mesh['triangles']).reshape(-1, 4)
    return indices[:, 0], v[indices[:, 1:]]


def parent_height(parents, triangles, parent, xy):
    heights = []
    for tri in triangles[parents == parent]:
        edges = np.stack([tri[1, :2] - tri[0, :2], tri[2, :2] - tri[0, :2]], axis=1)
        if abs(np.linalg.det(edges)) < 1e-12:
            continue
        u, v = np.linalg.solve(edges, xy - tri[0, :2])
        if u >= -1e-7 and v >= -1e-7 and u + v <= 1 + 1e-7:
            heights.append(float(tri[0, 2] * (1 - u - v) + tri[1, 2] * u + tri[2, 2] * v))
    return max(heights) if heights else None


def ray(model, origin, target):
    hit = model.cast(origin, target)
    return {'origin': list(origin), 'target': list(target), 'blocked': hit is not None, 'hit': hit}


def tower_corner(model):
    origin = np.asarray([42.00000000000001, 49.616666666666674, 8.227230405735702])
    direction = np.asarray([-.9990138064662089, -.04440061362071787, 0])
    return {'id': 'split-tower-corner-wall', 'map': 'split',
            'liveExactPoseVerified': False,
            'interpretation': 'Small cone is expected: a tall A Tower wall is about two meters ahead. Do not force this corner open.',
            'sourceObject': 'Bonsai_Art_ATower/Shell_6_ARampBuildingLeftTowerA_0/StaticMeshComponent0.108',
            'sourceFace': 1892377,
            'sourceTriangleMeters': [[40.0001335144043,46.62588882446289,7.726729393005371],
                                     [40.0001335144043,58.37411117553711,7.726729393005371],
                                     [40.0001335144043,46.62588882446289,9.849800109863281]],
            'modelRay': ray(model, origin, origin + direction * 3)}


def build(root, destination, gallery=None):
    baseline = root / 'tactical-visibility-revision/baseline-world'
    catalog = json.loads((baseline / 'height_catalog.json').read_text())['maps']
    sources = [fingerprint(baseline / 'height_catalog.json')]
    live_path = root.parent / '2026-09-05/in-game/evidence.json'
    live = json.loads(live_path.read_text())
    fit_path = root.parent / '2026-09-05/camera-fit-provisional.json'
    fit = json.loads(fit_path.read_text())
    old_path = root.parent / '2026-09-05/standing-precise/split/world-rays.json'
    old = json.loads(old_path.read_text())
    sources.extend(fingerprint(p) for p in [live_path, fit_path, old_path])
    for capture in live['captures']:
        actual = fingerprint(Path(capture['file']))
        assert actual['sha256'] == capture['sha256']
        sources.append(actual)
    split = ReferenceModel(baseline / 'split.height.bin.gz')
    rows = []
    for height, kind in [(1.75, 'standing-low-cover'), (1.95, 'height-sensitivity-only')]:
        old_ray = next(r for r in old['rays'] if r['id'] == f'44-{height}-18')
        r = ray(split, old_ray['startMeters'], old_ray['endMeters'])
        assert r['blocked']
        assert abs(r['hit']['distanceMeters'] - old_ray['distanceMeters']) < .001
        rows.append({'id': f'split-b-crate-{height}', 'map': 'split', 'category': kind,
                     'liveExactPoseVerified': False, 'liveLandmarkMatched': True,
                     'observerAboveFloorMeters': height, 'floorMeters': 3.0000009536743164,
                     'legacySourceRayId': old_ray['id'], 'legacyHitMeters': old_ray['distanceMeters'],
                     'sourceObject': 'Bonsai_Art_B/Shell_10_BSiteBackWallB_0',
                     'crateTopMeters': 4.00216007232666,
                     'openingLowerEdgeMeters': 4.8603, 'openingUpperEdgeMeters': 5.2372,
                     'modelRay': r,
                     'clearTargetBeforeWall': ray(split, r['origin'],
                         (np.asarray(r['origin']) + (np.asarray(r['target']) - r['origin']) / 25 * 1.5).tolist()),
                     'interpretation': 'Standing clears low crate and hits wall below decorative opening.' if height == 1.75 else
                         'Sensitivity plane enters recess then hits its angled back face. This is not a supported stance or evidence of a through-window.'})
    # Approximate live horizontal reference at the fitted XY, with working eye
    # height restored. Never adopt the weakly constrained fitted camera Z.
    origin = [*fit['standingCameraMeters'][:2], 4.750000953674316]
    target = [-35.3, (53.3812 + 54.135) / 2, origin[2]]
    rows.append({'id': 'split-live-landmark-horizontal', 'map': 'split',
                 'category': 'approximate-live-landmark-position',
                 'liveExactPoseVerified': False, 'liveLandmarkMatched': True,
                 'observerAboveFloorMeters': 1.75, 'floorMeters': 3.0000009536743164,
                 'modelRay': ray(split, origin, target),
                 'interpretation': 'Fixed fitted XY for repeatability only. Working standing eye is below the decorative opening. Live capture aim was upward and its exact pose remains unverified.'})
    del split
    overlap_path = root / 'tactical-visibility-revision/all-map-floor-sheets.json'
    overlaps = json.loads(overlap_path.read_text())['maps']
    sources.append(fingerprint(overlap_path))
    floors = []
    for name, summary in overlaps.items():
        if not summary['overlaps']:
            continue
        nav_file = baseline / catalog[name]['navigation']
        nav = json.loads(gzip.decompress(nav_file.read_bytes()))
        assert fingerprint(nav_file)['sha256'] == catalog[name]['navigationSha256']
        parents, triangles = floor_triangles(nav, catalog[name]['uiTransform'])
        fallback_parents, fallback_triangles = floor_triangles(nav, catalog[name]['uiTransform'], False)
        model = ReferenceModel(baseline / catalog[name]['pack'])
        chosen = sorted(summary['overlaps'], key=lambda r: (-r['areaMeters2'], r['parents']))[:2 if name == 'icebox' else 1]
        for index, overlap in enumerate(chosen):
            xy = np.asarray(overlap['point'])
            heights = [parent_height(parents, triangles, parent, xy) for parent in overlap['parents']]
            height_sources = ['detailed-floor' if h is not None else 'refined-navigation-fallback' for h in heights]
            heights = [h if h is not None else parent_height(fallback_parents, fallback_triangles, p, xy)
                       for h, p in zip(heights, overlap['parents'])]
            assert all(h is not None for h in heights)
            order = np.argsort(heights)
            lower, upper = [heights[i] for i in order]
            low_eye = [*xy, lower + 1.75]
            high_eye = [*xy, upper + 1.75]
            rays = []
            for direction in range(8):
                theta = direction * math.pi / 4
                offset = [math.cos(theta) * 6, math.sin(theta) * 6, 0]
                rays.append({'directionIndex': direction,
                             'lower': ray(model, low_eye, (np.asarray(low_eye) + offset).tolist()),
                             'upper': ray(model, high_eye, (np.asarray(high_eye) + offset).tolist())})
            floors.append({'id': f'{name}-overlap-{index}', 'map': name,
                           'category': 'overlapping-native-floor-branches',
                           'liveExactPoseVerified': False, 'originXY': xy.tolist(),
                           'parentPolygons': [overlap['parents'][i] for i in order],
                           'components': [overlap['components'][i] for i in order],
                           'floorMeters': [lower, upper], 'overlapAreaMeters2': overlap['areaMeters2'],
                           'floorHeightSources': [height_sources[i] for i in order],
                           'sourceNavigationSha256': catalog[name]['navigationSha256'],
                           'sourcePackSha256': catalog[name]['packSha256'],
                           'verticalBetweenStandingEyes': ray(model, low_eye, high_eye),
                           'horizontalRays': rays,
                           'interpretation': 'Same XY has two separate admitted floor branches. Component identity alone cannot choose a height. Separate observer and destination floors must remain distinguishable.'})
        del model
    corners = [tower_corner(ReferenceModel(baseline / catalog['split']['pack']))]
    document = {'version': 1, 'standingHeightMeters': 1.75,
                'scope': 'Independent source triangle ray fixtures and detailed navigation floor branches. Live Split evidence confirms landmarks only. No full gameplay certification.',
                'sources': sources, 'lowCoverCases': rows, 'overlapCases': floors, 'opaqueCornerCases': corners,
                'mapAssets': {name: {'packSha256': catalog[name]['packSha256'],
                                    'navigationSha256': catalog[name]['navigationSha256']}
                              for name in {'split', *(row['map'] for row in floors)}}}
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(document, indent=2) + '\n')
    print(f'Wrote {len(rows)} low-cover/landmark and {len(floors)} overlapping-floor fixtures: {destination}')
    if gallery:
        write_gallery(document, gallery)


def write_gallery(document, output):
    output.mkdir(parents=True, exist_ok=True)
    groups = {}
    def add(name, label, category, reference, extra):
        a, b = reference['origin'], reference['target']
        dx, dy = b[0] - a[0], b[1] - a[1]
        distance = math.hypot(dx, dy)
        groups.setdefault(name, []).append({'id': label, 'category': category,
            'query': [*a, dx / distance, dy / distance, 25, 103 * math.pi / 180], **extra})
    for row in document['lowCoverCases']:
        add('split', row['id'], row['category'], row['modelRay'], {'liveExactPoseVerified': False})
    for row in document['overlapCases']:
        def score(pair):
            a, b = pair['lower'], pair['upper']
            if a['blocked'] != b['blocked']:
                return 100
            return abs((a['hit']['distanceMeters'] if a['hit'] else 6) - (b['hit']['distanceMeters'] if b['hit'] else 6))
        pair = max(row['horizontalRays'], key=score)
        for index, floor in enumerate(['lower', 'upper']):
            add(row['map'], f"{row['id']}-{floor}",
                f"{floor} overlapping floor {row['floorMeters'][index]:.3f} m", pair[floor],
                {'parentPolygon': row['parentPolygons'][index], 'component': row['components'][index],
                 'pairedFloor': row['floorMeters']})
    for name, cases in groups.items():
        path = output / f'{name}-fixtures.json'
        payload = {'map': name, **document['mapAssets'][name], 'cases': cases}
        if path.exists() and json.loads(path.read_text()) != payload:
            raise ValueError(f'Refusing to change frozen gallery poses at {path}')
        path.write_text(json.dumps(payload, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--gallery', type=Path)
    args = parser.parse_args()
    build(args.root, args.output, args.gallery)
