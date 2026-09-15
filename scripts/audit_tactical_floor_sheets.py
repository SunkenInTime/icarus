"""Locate native ground polygons that cannot share one single-valued XY floor."""
import argparse
from collections import Counter
import gzip
import json
from pathlib import Path
import numpy as np
import shapely


def audit(pack_root, catalog_path, output):
    catalog = json.loads(catalog_path.read_text())['maps']
    reports = {}
    for name, entry in catalog.items():
        nav = json.loads(gzip.decompress((pack_root / entry['navigation']).read_bytes()))
        ui = entry['uiTransform']
        vertices = np.array(nav['vertices'], dtype=float).reshape(-1, 3)
        uv = vertices[:, :2] / nav['coordinateScale']
        vertices[:, 0] = (uv[:, 1] - ui['YScalarToAdd']) / (100 * ui['YMultiplier'])
        vertices[:, 1] = -(uv[:, 0] - ui['XScalarToAdd']) / (100 * ui['XMultiplier'])
        vertices[:, 2] = np.array(nav['refinedFloorHeightsCm']) / 100
        source = np.array(nav['triangles']).reshape(-1, 4)
        triangles_by_parent = {}
        for parent, a, b, c in source:
            triangles_by_parent.setdefault(int(parent), []).append(vertices[[a, b, c]])
        ids = np.flatnonzero(nav['walkable'])
        polygons = np.array([shapely.Polygon(vertices[nav['polygons'][i], :2]) for i in ids], dtype=object)
        tree = shapely.STRtree(polygons)
        first, second = tree.query(polygons, predicate='intersects')
        unique = first < second
        first, second = first[unique], second[unique]
        intersections = shapely.intersection(polygons[first], polygons[second])
        areas = shapely.area(intersections)
        admitted = areas > 1e-5
        overlaps = []
        def height(parent, xy):
            for triangle in triangles_by_parent[parent]:
                a = triangle[0, :2]
                edges = np.stack([triangle[1, :2] - a, triangle[2, :2] - a], axis=1)
                if abs(np.linalg.det(edges)) < 1e-12:
                    continue
                u, v = np.linalg.solve(edges, xy - a)
                if u >= -1e-7 and v >= -1e-7 and u + v <= 1 + 1e-7:
                    return float(triangle[0, 2] * (1 - u - v) + triangle[1, 2] * u + triangle[2, 2] * v)
            return None
        surfaces = []
        for a, b, geometry, area in zip(first[admitted], second[admitted], intersections[admitted], areas[admitted]):
            point = geometry.representative_point()
            xy = np.array([point.x, point.y])
            za, zb = height(int(ids[a]), xy), height(int(ids[b]), xy)
            if za is None or zb is None:
                raise ValueError(f'{name}: overlap point not covered by parent floor triangles')
            if abs(za - zb) <= .35:
                continue
            overlaps.append(dict(parents=[int(ids[a]), int(ids[b])], areaMeters2=float(area),
                                 point=xy.tolist(), floorHeightsMeters=[za, zb],
                                 components=[nav['components'][int(ids[a])], nav['components'][int(ids[b])]]))
            surfaces.append(geometry)
        union = shapely.union_all(polygons)
        area = float(shapely.union_all(surfaces).area) if surfaces else 0
        components = Counter(nav['components'][int(index)] for index in ids)
        slopes = [float(np.ptp(vertices[nav['polygons'][int(index)], 2])) for index in ids]
        reports[name] = dict(walkablePolygons=len(ids), groundComponents=len(components),
                             componentPolygonCounts=sorted(components.values(), reverse=True),
                             slopedOrSteppedPolygons=sum(span > .1 for span in slopes),
                             overlappingLayerPairs=len(overlaps), overlappingAreaMeters2=area,
                             walkableProjectedAreaMeters2=float(union.area),
                             overlappingAreaPercent=100 * area / union.area,
                             overlaps=overlaps)
        print(f'{name}: {len(overlaps)} stacked pairs, {area:.3f} m² / {100 * area / union.area:.3f}%, {len(components)} ground components', flush=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(dict(scope='Native parent-floor overlap audit. Detects real multi-valued ground; does not certify material blockers or near-edge extrapolation.', maps=reports), indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pack_root', type=Path)
    parser.add_argument('catalog', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    audit(args.pack_root, args.catalog, args.output)
