"""Diagnostic support-only slope filter, not a recovered game walkability rule."""
import argparse
import hashlib
import json
from pathlib import Path
import numpy as np
import shapely
from probe_source_floor_regressions import load_support, source_model


def run(revision, name):
    support = load_support(revision, name, True)
    source = source_model(revision, name, True)
    normals = np.cross(support.points[:, 1] - support.points[:, 0], support.points[:, 2] - support.points[:, 0])
    normal_z = abs(normals[:, 2]) / np.linalg.norm(normals, axis=1)
    excluded = (support.source_ids >= 0) & (normal_z < .65)
    support.polygons[excluded] = shapely.Polygon()
    support.tree = shapely.STRtree(support.polygons)
    roles = set()
    if name == 'fracture':
        role_path = revision / 'source-floor-audited-terrain-v2/fracture.terrain-role.json'
        roles = set(json.loads(role_path.read_text())['fullPackFaceIds'])
        fixtures = [('south', [73.48316666666666, -40.82916666666667, 7.2501]),
                    ('north', [104.90183333333333, 39.62116666666666, 6.75]),
                    ('lower', [85.5614583333, 29.125, 2.7262669]),
                    ('upper', [85.5614583333, 29.125, 7.25])]
    else:
        rows = json.loads((revision / f'gallery-all-map-lower-provisional-v1/{name}-fixtures.json').read_text())['cases']
        fixtures = [(row['id'], row['query'][:3]) for row in rows if row['id'] in
                    ('icebox-ramp-1-forward', 'icebox-ramp-2-reverse', 'ramp-1-forward', 'ramp-2-reverse')]
    assert fixtures
    folder = revision / 'steep-support-removal-control-v1'
    folder.mkdir(exist_ok=True)
    results = []
    code_hash = hashlib.sha256(Path('scripts/probe_source_floor_support.py').read_bytes()).hexdigest()
    for label, base in fixtures:
        samples = []
        for offset in (0, .01, -.01):
            origin = np.array(base) + [offset, 0, 0]
            for angle in range(360):
                direction = [np.cos(np.deg2rad(angle)), np.sin(np.deg2rad(angle))]
                result = support.cast(source, origin, direction, 65, True, True, True, .35, True,
                                      terrain_source_faces=roles)
                result.update(origin=origin.tolist(), angleRadians=float(np.deg2rad(angle)), offset=[offset, 0])
                samples.append(result)
            print(name, label, offset, 'complete', flush=True)
        results.append(dict(id=label, samples=samples))
        report = dict(scope=__doc__, map=name, selectorSha256=code_hash,
                      supportSha256=hashlib.sha256((revision / f'source-floor-support-all-walkable-v1/{name}.floor-support.npz').read_bytes()).hexdigest(),
                      excludedSupportFaces=int(excluded.sum()), visibilityFacesChanged=0,
                      excludedFullPackFaces=support.source_ids[excluded].tolist(), cases=results)
        (folder / f'{name}-continuity.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('revision', type=Path)
    parser.add_argument('--map', required=True, choices=['fracture', 'icebox'])
    args = parser.parse_args()
    run(args.revision, args.map)
