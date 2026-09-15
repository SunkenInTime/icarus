"""Clip actual upward Art surfaces to the player's navigation floor regions.

Floor triangles are separate from the Recast walking graph. Heights remain
piecewise planar, including stair tread edges. Multiple surfaces within one
parent polygon use the highest admitted surface; distinct parent polygons keep
stacked floors separate. No nearest roof or interpolated stair ramp is invented.
"""
import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path
import time

import numpy as np
import shapely
from shapely import Polygon, STRtree

FLOOR_COORDINATE_SCALE = 100_000_000


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def plane(points):
    n = np.cross(points[1] - points[0], points[2] - points[0])
    return np.array((-n[0] / n[2], -n[1] / n[2], np.dot(n, points[0]) / n[2]))


def clip_halfplane(points, coefficients, maximum):
    """Clip convex XY points to a*x+b*y+c <= maximum."""
    if not points:
        return []
    output = []
    previous = points[-1]
    previous_value = float(np.dot(coefficients[:2], previous) + coefficients[2] - maximum)
    for current in points:
        value = float(np.dot(coefficients[:2], current) + coefficients[2] - maximum)
        if (value <= 0) != (previous_value <= 0):
            t = previous_value / (previous_value - value)
            output.append(tuple(previous[i] + t * (current[i] - previous[i]) for i in range(2)))
        if value <= 0:
            output.append(tuple(current))
        previous, previous_value = current, value
    return output


def bake(world, navigation, output):
    started = time.perf_counter()
    source = json.loads(navigation.read_text(encoding='utf8'))
    metadata = json.loads((world / 'geometry.json').read_text(encoding='utf8'))
    if digest(world / 'geometry.npz') != metadata['geometrySha256']:
        raise ValueError('Stale world geometry')
    raw = np.load(world / 'geometry.npz')
    points, faces = raw['points'], raw['faces']
    xyz = points[faces]
    normals = np.cross(xyz[:, 1] - xyz[:, 0], xyz[:, 2] - xyz[:, 0])
    lengths = np.linalg.norm(normals, axis=1)
    solid = np.array([m['category'] in ('opaque', 'unresolved') for m in metadata['materials']])
    allowed = ((normals[:, 2] > .65 * lengths) &
               solid[raw['material_indices']])
    from ground_floor_policy import ground_policy_mask, FloorOverrides
    allowed, ground_proof, support_data = ground_policy_mask(world, metadata, raw, navigation)
    overrides = FloorOverrides(world, raw, support_data)
    xyz = xyz[allowed]
    materials = raw['material_indices'][allowed]
    normals = normals[allowed]
    planes = np.column_stack((-normals[:, 0] / normals[:, 2],
                              -normals[:, 1] / normals[:, 2],
                              np.einsum('ij,ij->i', normals, xyz[:, 0]) / normals[:, 2]))
    del normals, lengths
    floor_polygons = shapely.polygons(xyz[:, :, :2])
    tree = STRtree(floor_polygons)
    nav_vertices = np.asarray(source['vertices'], dtype=float).reshape(-1, 3) / 100
    nav_vertices[:, 1] *= -1
    nav_triangles = np.asarray(source['triangles'], dtype=int).reshape(-1, 4)
    print(json.dumps({'map': source['map'], 'upwardFaces': len(xyz),
                      'navTriangles': len(nav_triangles)}), flush=True)
    groups = defaultdict(list)
    unresolved_groups = set()
    clipped = 0
    for nav_polygon, a, b, c in nav_triangles:
        nav_points = nav_vertices[[a, b, c]]
        nav_plane = plane(nav_points)
        shape = Polygon(nav_points[:, :2])
        override_pieces = overrides.pieces(int(nav_polygon), nav_points)
        override_domain = shapely.union_all([piece for _,piece in override_pieces]) if override_pieces else None
        for coefficients,piece in override_pieces:
            key=(int(nav_polygon),*(round(float(value),6 if i<2 else 4) for i,value in enumerate(coefficients)))
            groups[key].append(piece)
        candidates = tree.query(shape, predicate='intersects')
        # Reject floor strata outside the same navigation triangle's vertical
        # window before doing polygon intersections. Exact plane clipping below
        # handles ramps that enter or leave the window inside a triangle.
        differences = xyz[candidates, :, 2] - (
            xyz[candidates, :, 0] * nav_plane[0] +
            xyz[candidates, :, 1] * nav_plane[1] + nav_plane[2])
        candidates = candidates[(differences.min(axis=1) <= .30001) &
                                (differences.max(axis=1) >= -.60001)]
        intersections = shapely.intersection(floor_polygons[candidates], shape)
        for face, intersection in zip(candidates, intersections):
            if intersection.geom_type != 'Polygon' or intersection.area < 1e-8:
                continue
            points2d = list(intersection.exterior.coords)[:-1]
            difference = planes[face] - nav_plane
            points2d = clip_halfplane(points2d, difference, .30001)
            points2d = clip_halfplane(points2d, -difference, .60001)
            if len(points2d) < 3:
                continue
            piece = Polygon(points2d)
            if override_domain is not None:
                piece = piece.difference(override_domain)
            if piece.area < 1e-8:
                continue
            # This merges coplanar mesh tessellation while retaining sub-mm
            # vertical precision and explicit edges between stair heights.
            coefficients = tuple(round(float(v), 6 if i < 2 else 4)
                                 for i, v in enumerate(planes[face]))
            key = (int(nav_polygon), *coefficients)
            groups[key].append(piece)
            if metadata['materials'][int(materials[face])]['category'] == 'unresolved':
                unresolved_groups.add(key)
            clipped += 1
    print(json.dumps({'map': source['map'], 'clippedPieces': clipped,
                      'planeGroups': len(groups), 'seconds': time.perf_counter() - started}), flush=True)
    ui = metadata['uiTransform']
    vertices, triangles, vertex_ids, seen_triangles = [], [], {}, set()
    uncertain_triangles = 0
    max_quantization_error_cm = 0.0

    def vertex(point, coefficients):
        x, y = point
        z = coefficients[0] * x + coefficients[1] * y + coefficients[2]
        u = (-y * 100 * ui['XMultiplier'] + ui['XScalarToAdd']) * FLOOR_COORDINATE_SCALE
        v = (x * 100 * ui['YMultiplier'] + ui['YScalarToAdd']) * FLOOR_COORDINATE_SCALE
        encoded = (round(u), round(v), round(z * 100, 2))
        nonlocal max_quantization_error_cm
        max_quantization_error_cm = max(max_quantization_error_cm, abs(encoded[2] - z * 100))
        if encoded not in vertex_ids:
            vertex_ids[encoded] = len(vertices) // 3
            vertices.extend(encoded)
        return vertex_ids[encoded]

    for key, pieces in sorted(groups.items()):
        parent, *coefficients = key
        merged = shapely.union_all(pieces, grid_size=.0000001)
        triangulated = shapely.constrained_delaunay_triangles(merged)
        for triangle in shapely.get_parts(triangulated):
            if triangle.area < 1e-8:
                continue
            ids = tuple(vertex(p, coefficients) for p in list(triangle.exterior.coords)[:-1])
            if len(ids) != 3 or len(set(ids)) != 3:
                continue
            # Quantized UV can collapse a very narrow triangle. Reject it before
            # the runtime floor index divides by its projected area.
            uv = [vertices[i * 3:i * 3 + 2] for i in ids]
            area = (uv[1][0] - uv[0][0]) * (uv[2][1] - uv[0][1]) - (
                uv[1][1] - uv[0][1]) * (uv[2][0] - uv[0][0])
            if area == 0:
                continue
            identity = (parent, *sorted(ids))
            if identity in seen_triangles:
                continue
            seen_triangles.add(identity)
            triangles.extend((parent, *ids))
            uncertain_triangles += key in unresolved_groups
    report = {'schemaVersion': 1, 'map': source['map'],
              'navigationSha256': source['navigationSha256'],
              'sourceXYZSha256': digest(navigation),
              'geometrySha256': metadata['geometrySha256'],
              **ground_proof,
              'floorMesh': {'coordinateScale': FLOOR_COORDINATE_SCALE, 'vertices': vertices, 'triangles': triangles},
              'summary': {'sourceUpwardFaces': len(xyz), 'clippedPieces': clipped,
                          'planeGroups': len(groups), 'vertices': len(vertices) // 3,
                          'triangles': len(triangles) // 4,
                          'unresolvedMaterialTriangles': uncertain_triangles,
                          'maxZQuantizationErrorCm': max_quantization_error_cm,
                          'seconds': time.perf_counter() - started}}
    output.write_text(json.dumps(report, separators=(',', ':')), encoding='utf8')
    print(json.dumps(report['summary']), flush=True)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--world', required=True, type=Path)
    parser.add_argument('--navigation', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    bake(args.world, args.navigation, args.output)


if __name__ == '__main__':
    main()
