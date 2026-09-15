"""Inspect failed same-plane rays against nearby original 3D triangles.

This is a diagnostic, not an acceptance filter. It retains every outlier and
shows independent double-precision triangle intersections at the nominal plane,
its float32 representation and one micrometre above/below it. These comparisons
can distinguish grazing top edges from missing boundaries or wrong materials.
"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np


def intersection(triangle, origin, direction):
    a, b = triangle[1] - triangle[0], triangle[2] - triangle[0]
    cross = np.cross(direction, b)
    determinant = float(np.dot(a, cross))
    if abs(determinant) <= 1e-14 * np.linalg.norm(a) * np.linalg.norm(b):
        return {'parallelOrDegenerate': True}
    offset = origin - triangle[0]
    other = np.cross(offset, a)
    u, v = float(np.dot(offset, cross) / determinant), float(np.dot(direction, other) / determinant)
    distance = float(np.dot(b, other) / determinant)
    barycentric = [1 - u - v, u, v]
    return {'barycentric': barycentric, 'distanceMeters': distance,
            'closedHitWithinNumericTolerance': distance >= 0 and min(barycentric) >= -1e-12,
            'facingDot': float(np.dot(np.cross(a, b), direction))}


def explain(world, reference_path, comparison_path, output_path, radius_meters=.001):
    world, output_path = Path(world), Path(output_path)
    metadata = json.loads((world / 'geometry.json').read_bytes())
    reference = json.loads(Path(reference_path).read_bytes())
    comparison = json.loads(Path(comparison_path).read_bytes())
    digest = lambda path: hashlib.sha256(Path(path).read_bytes()).hexdigest()
    if metadata['geometrySha256'] != digest(world / 'geometry.npz'):
        raise ValueError('Geometry fingerprint mismatch.')
    if (reference['map'] != metadata['map'] or
            reference['source']['geometrySha256'] != metadata['geometrySha256']):
        raise ValueError('Reference world does not match.')
    if comparison.get('map') != metadata['map'] or comparison.get('referenceSha256') != digest(reference_path):
        raise ValueError('Outlier comparison does not belong to this exact reference.')
    if not np.isfinite(radius_meters) or radius_meters <= 0:
        raise ValueError('Candidate search radius must be positive.')
    raw = np.load(world / 'geometry.npz')
    triangles = raw['points'][raw['faces']].astype(np.float64)
    low, high = triangles.min(axis=1), triangles.max(axis=1)
    rays = {ray['id']: ray for ray in reference['rays']}
    objects = sorted(metadata['objects'], key=lambda row: row['firstFace'])
    first_faces = np.asarray([row['firstFace'] for row in objects])
    rows = []
    for failure in comparison['planeFailures']:
        ray = rays[failure['ray']]
        origin = np.asarray(ray['startMeters'], dtype=np.float64)
        origin[2] = failure['elevationCm'] / 100
        direction = np.asarray(ray['endMeters']) - ray['startMeters']
        direction /= np.linalg.norm(direction)
        hit = origin + direction * failure['bakedMeters']
        candidates = np.flatnonzero(((low <= hit + radius_meters) & (high >= hit - radius_meters)).all(axis=1))
        details = []
        for face in candidates:
            face = int(face)
            triangle = triangles[face]
            tests = []
            rounded = float(np.float32(origin[2]))
            for kind, height in (('nominal-double', origin[2]), ('float32-plane', rounded),
                                 ('one-micrometre-below', rounded - 1e-6),
                                 ('one-micrometre-above', rounded + 1e-6)):
                start = origin.copy()
                start[2] = height
                result = intersection(triangle, start, direction)
                if 'distanceMeters' in result:
                    result['differenceFromBakedMeters'] = result['distanceMeters'] - failure['bakedMeters']
                tests.append({'kind': kind, 'heightMeters': height, **result})
            object_index = int(np.searchsorted(first_faces, face, side='right')) - 1
            obj = objects[object_index] if object_index >= 0 else None
            if obj and not obj['firstFace'] <= face < obj['firstFace'] + obj['faceCount']:
                obj = None
            details.append({'sourceFace': face, 'object': obj['path'] if obj else None,
                            'points': triangle.tolist(),
                            'material': metadata['materials'][int(raw['material_indices'][face])],
                            'intersections': tests})
        rows.append({'failure': failure, 'origin': origin.tolist(), 'direction': direction.tolist(),
                     'bakedHit': hit.tolist(), 'nearbySourceTriangles': details})
    result = {'map': metadata['map'], 'status': 'diagnostic-requires-review',
              'acceptedOrWaivedRays': 0, 'candidateRadiusMeters': radius_meters,
              'geometrySha256': metadata['geometrySha256'], 'referenceSha256': digest(reference_path),
              'comparisonSha256': digest(comparison_path), 'scriptSha256': digest(__file__), 'rays': rows}
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(result, indent=2, allow_nan=False), encoding='utf-8')
    print(json.dumps({'map': metadata['map'], 'outliersInspected': len(rows),
                      'withNearbyTriangles': sum(bool(row['nearbySourceTriangles']) for row in rows)}))
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('world', 'reference', 'comparison', 'output'):
        parser.add_argument(name, type=Path)
    parser.add_argument('--radius-meters', type=float, default=.001)
    args = parser.parse_args()
    explain(args.world, args.reference, args.comparison, args.output, args.radius_meters)
