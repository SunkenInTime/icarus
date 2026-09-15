"""Prove inverse display receivers and navigation stay inside retained native scope."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path

import numpy as np
import shapely

from tactical_alignment_scope import controls
from tactical_alignment_warps import load_warp


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def map_shape(shape, origin, matrix):
    return shapely.transform(shape, lambda xy: xy @ matrix.T + origin)


def mapped_domain(domain, source, target, triangles):
    polygons = shapely.polygons(source[triangles])
    tree = shapely.STRtree(polygons)
    parts = []
    for index in tree.query(domain, predicate='intersects'):
        intersection = domain.intersection(polygons[index])
        if intersection.area == 0:
            continue
        a, b = source[triangles[index]], target[triangles[index]]
        matrix = np.column_stack((b[1] - b[0], b[2] - b[0])) @ np.linalg.inv(np.column_stack((a[1] - a[0], a[2] - a[0])))
        parts.append(map_shape(intersection, b[0] - matrix @ a[0], matrix))
    parts.append(domain.difference(shapely.union_all(polygons)))
    return shapely.union_all(parts)


def nav_points(path, meta):
    nav = json.loads(gzip.decompress(path.read_bytes()))
    ids = np.unique(np.concatenate([p for p, walkable in zip(nav['polygons'], nav['walkable']) if walkable]))
    uv = np.array(nav['vertices']).reshape(-1, 3)[ids, :2] / nav['coordinateScale']
    ui = meta['uiTransform']
    return np.column_stack(((uv[:, 1] - ui['YScalarToAdd']) / (100 * ui['YMultiplier']),
                            -(uv[:, 0] - ui['XScalarToAdd']) / (100 * ui['XMultiplier'])))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--inventory', type=Path, required=True)
    parser.add_argument('--display-directory', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    catalog = json.loads(Path('assets/maps/world/height_catalog.json').read_text())['maps']
    rows = []
    args.output.mkdir(parents=True, exist_ok=False)
    for row in json.loads(args.inventory.read_text())['maps']:
        name = row['map']
        scope_path = args.root / f'compact-prototype/all-map-svg-foliage-v2/{name}/scope.json'
        scope = json.loads(scope_path.read_text())
        if scope['geometrySha256'] != catalog[name]['sourceGeometrySha256']:
            raise ValueError(f'{name}: source scope geometry mismatch')
        hull = shapely.from_geojson(scope['nativeObserverReceiverHull'])
        display_path = args.display_directory / f'{name}.display-warp.json.gz'
        display = json.loads(gzip.decompress(display_path.read_bytes()))
        source = np.array(display['sourceNativeMeters']).reshape(-1, 2)
        projection = display['projection']
        origin = np.array(projection['origin'])
        matrix = np.column_stack((projection['axisU'], projection['axisV']))
        inverse = np.linalg.inv(matrix)
        target = (np.array(display['targetAttackSvg']).reshape(-1, 2) - origin) @ inverse.T
        triangles = np.array(display['triangles']).reshape(-1, 3)
        target_hull = mapped_domain(hull, source, target, triangles)
        receiver = []
        for side, suffix in [('attack', ''), ('defense', '_defense')]:
            path = Path(f'assets/maps/{name}_map{suffix}.svg')
            if sha(path) != display['art'][side]['sha256']:
                raise ValueError('Receiver artwork changed')
            xy = controls(path)
            if side == 'defense':
                xy = np.array(display['attackToDefenseSvg']['origin']) - xy
            receiver.extend((xy - origin) @ inverse.T)
        candidate_nav = nav_points(Path(row['navigation']), catalog[name])
        original_nav = nav_points(Path(f'assets/maps/world/{name}_navigation.json.gz'), catalog[name])
        proof = json.loads(Path(row['proof']).read_text())
        warp = load_warp(Path(proof['controlConstraints']['path']))
        mapped_original_nav = (warp.apply(original_nav @ matrix.T + origin) - origin) @ inverse.T
        # Bezier curves stay inside their control hull. Taking the joint convex
        # hull is conservative for every painted receiver and valid nav point.
        desired = shapely.MultiPoint(np.vstack((receiver, candidate_nav, mapped_original_nav))).convex_hull
        source_preimage = mapped_domain(desired, target, source, triangles)
        numerical_allowance = 1e-8
        outside = source_preimage.difference(hull)
        failed = source_preimage.difference(hull.buffer(numerical_allowance))
        points = shapely.get_coordinates(source_preimage)
        max_distance = float(shapely.distance(shapely.points(points), hull).max(initial=0))
        record = {
            'map': name, 'sourceScopeSha256': sha(scope_path), 'displayWarpSha256': sha(display_path),
            'sourceGeometrySha256': scope['geometrySha256'],
            'correctedNavigationSha256': sha(Path(row['navigation'])),
            'receiverControls': len(receiver), 'correctedNavigationVertices': len(candidate_nav),
            'mappedOriginalNavigationVertices': len(mapped_original_nav),
            'sourceScopeCoversInverseReceiverAndNavigationHull': failed.is_empty,
            'numericalBoundaryAllowanceMeters': numerical_allowance,
            'maximumPreimageVertexOutsideSourceMeters': max_distance,
            'unbufferedOutsideAreaMeters2': float(outside.area),
            'outsideAreaBeyondAllowanceMeters2': float(failed.area),
            'transformedSourceHullCoversOriginalHull': target_hull.buffer(numerical_allowance).covers(hull),
            'nativeSourceHullConvex': hull.equals(hull.convex_hull),
            'reason': 'Exact inverse affine image of the complete receiver-control and navigation convex hull at every display mesh cell. Native source scope is convex, so straight native rays between admitted observers and receiver destinations remain inside the retained envelope.'
        }
        (args.output / f'{name}.json').write_text(json.dumps(record, indent=2))
        rows.append(record)
        print(name, record['sourceScopeCoversInverseReceiverAndNavigationHull'], max_distance, flush=True)
    (args.output / 'summary.json').write_text(json.dumps({'maps': rows, 'allPassed': all(r['sourceScopeCoversInverseReceiverAndNavigationHull'] for r in rows)}, indent=2))


if __name__ == '__main__':
    main()
