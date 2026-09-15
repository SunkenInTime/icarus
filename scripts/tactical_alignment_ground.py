"""Compose the local XY field with a continuous tactical ground field."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path

import numpy as np
from shapely import Polygon, constrained_delaunay_triangles, union_all

from tactical_alignment_candidate import Warp
from tactical_alignment_audit import projection
from tactical_alignment_cells import clip_triangle, cross


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--audit-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--warp-file', type=Path)
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError(args.output)
    compressed = args.source.read_bytes()
    field = json.loads(gzip.decompress(compressed))
    if field['coordinateSpace'] != 'native-meters':
        raise ValueError('Expected a native ground field')
    name = field['map']
    catalog = json.loads(Path('assets/maps/world/height_catalog.json').read_text())['maps'][name]
    registration = json.loads((args.audit_root / f'registration/results/{name}-registration.json').read_text())
    project = projection(catalog, registration)
    origin = project(np.zeros(2))
    matrix = np.column_stack((project(np.array([1., 0])) - origin, project(np.array([0., 1])) - origin))
    inverse = np.linalg.inv(matrix)
    if args.warp_file:
        from tactical_alignment_warps import load_warp
        warp = load_warp(args.warp_file)
    elif name == 'split':
        warp = Warp()
    else:
        raise ValueError('A per-map warp file is required')
    if not np.any(warp.delta):
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(compressed)
        proof = {'identityWarpPreservesSourceBytes': True, 'candidateFieldSha256': hashlib.sha256(compressed).hexdigest(), 'bytes': len(compressed)}
        args.output.with_suffix('.proof.json').write_text(json.dumps(proof, indent=2))
        print(json.dumps(proof, indent=2))
        return
    active = np.any(np.linalg.norm(warp.delta[warp.tri.simplices], axis=2) > 0, axis=1)
    cells = warp.points[warp.tri.simplices[active]]
    domain = union_all([Polygon(cell) for cell in cells])
    cell_lo, cell_hi = cells.min(1), cells.max(1)
    vertices = np.array(field['vertices']).reshape(-1, 3)
    triangles = np.array(field['triangles']).reshape(-1, 3)
    xy = project(vertices[:, :2])
    new_vertices, new_triangles = [], []
    max_area_error, max_affine_error, max_z_error = 0., 0., 0.
    for ids in triangles:
        source, points = vertices[ids], xy[ids]
        original_area = abs(cross(points[1] - points[0], points[2] - points[0])) / 2
        pieces = []
        for cell in np.flatnonzero(np.all(cell_hi >= points.min(0), axis=1) & np.all(cell_lo <= points.max(0), axis=1)):
            bary = clip_triangle(points, cells[cell])
            pieces.extend(np.array([bary[0], bary[i], bary[i + 1]]) for i in range(1, len(bary) - 1))
        # Only active cells need partitioning; W is exactly identity elsewhere.
        remainder = Polygon(points).difference(domain)
        if not remainder.is_empty:
            source_matrix = np.vstack((points.T, np.ones(3)))
            for triangle in constrained_delaunay_triangles(remainder).geoms:
                target = np.array(triangle.exterior.coords)[:3]
                pieces.append(np.linalg.solve(source_matrix, np.vstack((target.T, np.ones(3)))).T)
        covered = 0.
        for bary in pieces:
            before = bary @ points
            area = abs(cross(before[1] - before[0], before[2] - before[0])) / 2
            if area < 1e-12:
                continue
            covered += area
            target = warp.apply(before)
            z = bary @ source[:, 2]
            first = len(new_vertices)
            new_vertices.extend(np.column_stack(((target - origin) @ inverse.T, z)).tolist())
            new_triangles.append([first, first + 1, first + 2])
            max_affine_error = max(max_affine_error, float(np.linalg.norm(target.mean(0) - warp.apply(before.mean(0)))))
            max_z_error = max(max_z_error, float(abs(z.mean() - bary.mean(0) @ source[:, 2])))
        max_area_error = max(max_area_error, abs(covered - original_area) / max(original_area, 1e-20))
    if max_area_error > 1e-7 or max_affine_error > 1e-7:
        raise ValueError(f'Ground partition failed: {max_area_error}, {max_affine_error}')
    field['vertices'] = np.array(new_vertices).ravel().tolist()
    field['triangles'] = np.array(new_triangles).ravel().tolist()
    field['xyRegistration'] = {'policy': f'{name}-local-structural-alignment-v1',
        'sourceFieldSha256': hashlib.sha256(compressed).hexdigest(),
        'sourceTriangles': len(triangles), 'candidateTriangles': len(new_triangles),
        'maximumSourceAreaRelativeError': max_area_error,
        'maximumChildAffineCentroidErrorSvg': max_affine_error,
        'maximumBarycentricHeightErrorMeters': max_z_error,
        'semantics': 'f_new(W(x,y)) = f_old(x,y); field triangle XY split with the same W as geometry and navigation, barycentric height preserved.'}
    encoded = gzip.compress(json.dumps(field, separators=(',', ':')).encode(), compresslevel=9, mtime=0)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(encoded)
    proof = {**field['xyRegistration'], 'candidateFieldSha256': hashlib.sha256(encoded).hexdigest(), 'bytes': len(encoded)}
    args.output.with_suffix('.proof.json').write_text(json.dumps(proof, indent=2))
    print(json.dumps(proof, indent=2))


if __name__ == '__main__':
    main()
