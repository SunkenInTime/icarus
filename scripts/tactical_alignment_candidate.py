"""Create an isolated, reversible Split wall-registration candidate.

The two correspondences are supported by the annotated-scene source-face audit.
The floor lip near Clove is deliberately unmodified: its SVG correspondence is ambiguous.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import struct
import time

import numpy as np
from scipy.spatial import Delaunay
from tactical_alignment_audit import pack, projection, section, first_hit


def sha(data):
    return hashlib.sha256(data).hexdigest()


def plateau(values, bounds):
    a, b, c, d = bounds
    return np.minimum(np.clip((values - a) / (b - a), 0, 1), np.clip((d - values) / (d - c), 0, 1))


class Warp:
    def __init__(self):
        self.xs = np.array([-200, 232, 240, 318, 326, 328, 337.9172, 357.4832, 369, 700])
        self.ys = np.array([-200, 72, 82, 88, 99, 234, 247.648, 273.2567, 286, 700])
        self.points = np.array([(x, y) for y in self.ys for x in self.xs])
        self.tri = Delaunay(self.points)
        self.delta = np.zeros_like(self.points)
        x, y = self.points.T
        self.delta[:, 1] -= (85.39873493966076 - 83.9221) * plateau(x, [232, 240, 318, 326]) * plateau(y, [72, 82, 88, 99])
        influence = plateau(x, [328, 337.9172, 357.4832, 369]) * plateau(y, [234, 247.648, 273.2567, 286])
        scale = (357.755 - 338.617) / (357.4832 - 337.9172)
        self.delta[:, 0] += (338.617 + (x - 337.9172) * scale - x) * influence
        self.delta[:, 1] += (248.196 - 247.64799131114702) * influence
        source = self.points[self.tri.simplices]
        target = source + self.delta[self.tri.simplices]
        cross = lambda a: (a[:, 1, 0] - a[:, 0, 0]) * (a[:, 2, 1] - a[:, 0, 1]) - (a[:, 1, 1] - a[:, 0, 1]) * (a[:, 2, 0] - a[:, 0, 0])
        self.jacobians = cross(target) / cross(source)
        if np.min(self.jacobians) <= 0:
            raise ValueError('Warp folds its domain')

    def apply(self, points):
        points = np.asarray(points)
        shape = points.shape
        flat = points.reshape(-1, 2)
        result = flat.copy()
        for start in range(0, len(flat), 200000):
            rows = flat[start:start + 200000]
            cells = self.tri.find_simplex(rows)
            admitted = cells >= 0
            transform = self.tri.transform[cells[admitted]]
            b = np.einsum('nij,nj->ni', transform[:, :2], rows[admitted] - transform[:, 2])
            bary = np.column_stack((b, 1 - b.sum(1)))
            delta = np.einsum('ni,nij->nj', bary, self.delta[self.tri.simplices[cells[admitted]]])
            result[start:start + len(rows)][admitted] += delta
        return result.reshape(shape)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audit-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--split-cells', action='store_true')
    parser.add_argument('--split-navigation', action='store_true')
    parser.add_argument('--map', default='split')
    parser.add_argument('--warp-file', type=Path)
    parser.add_argument('--pack', type=Path)
    parser.add_argument('--navigation', type=Path)
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError('Use a new candidate folder; preserve prior evidence.')
    args.output.mkdir(parents=True)
    root, out = args.audit_root, args.output
    name = args.map
    catalog = json.loads(Path('assets/maps/world/height_catalog.json').read_text())['maps'][name]
    registration = json.loads((root / f'registration/results/{name}-registration.json').read_text())
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
    def native_warp(xy):
        return (warp.apply(project(xy)) - origin) @ inverse.T
    packed = args.pack or Path(f'assets/maps/world/{name}.height.bin.gz')
    compressed = packed.read_bytes()
    raw = bytearray(gzip.decompress(compressed))
    header, arrays = pack(packed)
    header_size = struct.unpack_from('<I', raw, 4)[0]
    base = (8 + header_size + 7) // 8 * 8
    old_vertices = arrays['vertices']
    vertices = old_vertices.copy()
    vertices[:, :2] = native_warp(vertices[:, :2])
    faces, nodes = arrays['faces'], arrays['nodes']
    bounds = arrays['bounds'].copy()
    # Keep the verified face order and topology, refit every leaf/parent AABB.
    for i in range(len(nodes) - 1, -1, -1):
        start, count, left, right = nodes[i]
        if count:
            triangle_vertices = vertices[faces[start:start + count]].reshape(-1, 3)
            bounds[i] = [*triangle_vertices.min(0), *triangle_vertices.max(0)]
        else:
            bounds[i] = [*np.minimum(bounds[left, :3], bounds[right, :3]), *np.maximum(bounds[left, 3:], bounds[right, 3:])]
    for array_name, data in [('vertices', vertices), ('bounds', bounds)]:
        offset = base + header['arrays'][array_name]['offset']
        raw[offset:offset + data.nbytes] = data.tobytes()
    candidate = gzip.compress(raw, compresslevel=9, mtime=0)
    cell_report = None
    candidate_arrays = None
    if args.split_cells and np.any(warp.delta):
        from tactical_alignment_cells import split_arrays, encode
        candidate_arrays, parents, cell_report = split_arrays(arrays, project, lambda xy: (xy - origin) @ inverse.T, warp)
        raw, candidate = encode(header, candidate_arrays, gzip.decompress(compressed))
        np.savez_compressed(out / 'candidate-parent-faces.npz', parents=parents)
    elif args.split_cells:
        raw, candidate = gzip.decompress(compressed), compressed
        cell_report = {'splitSourceFaces': 0, 'candidateFaces': len(faces), 'addedFaces': 0, 'addedVertices': 0,
                       'maximumChildAffineCentroidErrorSvg': 0., 'maximumSourceAreaRelativeError': 0.,
                       'identityWarpPreservesSourceBytes': True}
        np.savez_compressed(out / 'candidate-parent-faces.npz', parents=np.arange(len(faces), dtype=np.uint32))
    (out / f'{name}.height.bin.gz').write_bytes(candidate)
    # Navigation and its detailed floor mesh receive exactly the same XY field.
    nav_path = args.navigation or Path(f'assets/maps/world/{name}_navigation.json.gz')
    nav_bytes = nav_path.read_bytes()
    nav = json.loads(gzip.decompress(nav_bytes))
    ui = catalog['uiTransform']
    def uv_to_native(uv):
        return np.column_stack(((uv[:, 1] - ui['YScalarToAdd']) / (100 * ui['YMultiplier']), -(uv[:, 0] - ui['XScalarToAdd']) / (100 * ui['XMultiplier'])))
    def native_to_uv(xy):
        return np.column_stack((ui['XScalarToAdd'] - xy[:, 1] * 100 * ui['XMultiplier'], ui['YScalarToAdd'] + xy[:, 0] * 100 * ui['YMultiplier']))
    nav_proof = None
    if args.split_navigation:
        from tactical_alignment_navigation import warp_navigation
        nav, nav_proof = warp_navigation(nav, lambda uv: project(uv_to_native(uv)), lambda xy: native_to_uv((xy - origin) @ inverse.T), warp)
    for target in [nav, nav['floorMesh']]:
        if args.split_navigation:
            break
        data = np.array(target['vertices'], dtype=float).reshape(-1, 3)
        xy = data[:, :2] / target['coordinateScale']
        warped = native_to_uv(native_warp(uv_to_native(xy)))
        data[:, :2] = np.rint(warped * target['coordinateScale'])
        target['vertices'] = [int(value) if i % 3 != 2 else float(value) for i, value in enumerate(data.ravel())]
    if not args.split_navigation:
        links = np.array(nav['links'], dtype=float).reshape(-1, 6)
        for columns in [slice(2, 4), slice(4, 6)]:
            links[:, columns] = np.rint(native_to_uv(native_warp(uv_to_native(links[:, columns] / nav['coordinateScale']))) * nav['coordinateScale'])
        nav['links'] = links.astype(np.int64).ravel().tolist()
    nav_candidate = gzip.compress(json.dumps(nav, separators=(',', ':')).encode(), compresslevel=9, mtime=0)
    (out / f'{name}_navigation.json.gz').write_bytes(nav_candidate)
    # Source triangles crossing warp cells may only approximate the continuous
    # field if transformed by their vertices. Quantify before allowing adoption.
    maximum_error = 0.
    error_count = 0
    for start in range(0, len(faces), 100000):
        ids = faces[start:start + 100000]
        source = project(old_vertices[ids, :2]).mean(1)
        vertex_interpolation = project(vertices[ids, :2]).mean(1)
        error = np.linalg.norm(warp.apply(source) - vertex_interpolation, axis=1)
        maximum_error = max(maximum_error, float(error.max()))
        error_count += int((error > .01).sum())
    diagnostics = json.loads((root / f'tactical-alignment-v1/{name}.json').read_text()).get('markedRayDiagnostics', []) if name == 'split' and not args.pack else []
    new_arrays = candidate_arrays if candidate_arrays is not None else {**arrays, 'vertices': vertices, 'bounds': bounds}
    ray_records = []
    for item in diagnostics:
        segments, _ = section(new_arrays, item['heightMeters'], vertical_only=False)
        _, distance, hit = first_hit(np.array(item['originSvgExactFixture']), np.array(item['targetSvgApproximateFromAnnotation']), project(segments))
        ray_records.append({'label': item['label'], 'beforeHitSvg': item['solidSourceFirstHitSvg'], 'afterHitSvg': hit.tolist(),
                            'beforeDistanceSvg': item['sourceDistanceSvg'], 'afterDistanceSvg': distance})
    report = {'format': 'icarus-local-registration-candidate-v1', 'map': name, 'adopted': False,
              'sourcePackSha256': sha(compressed), 'candidatePackSha256': sha(candidate), 'candidateRawSha256': sha(raw),
              'sourceNavigationSha256': sha(nav_bytes), 'candidateNavigationSha256': sha(nav_candidate),
              'preserved': ['vertex Z bit patterns', 'face topology/order', 'alpha UV/materials/textures', 'SVGs', 'saved canvas coordinates'],
              'changed': ['all geometry XY under continuous local field', 'navigation XY', 'detailed floor XY', 'BVH bounds'],
              'controlConstraints': ['Deadlock front facade Y85.39873494 -> SVG83.9221', 'Iso generator left X337.9172 -> SVG338.617', 'Iso generator right X357.4832 -> SVG357.755', 'Iso generator upper Y247.64799131 -> SVG248.196'],
              'ambiguitiesNotChanged': ['Clove mailroom floor lip has no reliable SVG structural counterpart'],
              'minimumCellJacobian': float(warp.jacobians.min()), 'maximumCellJacobian': float(warp.jacobians.max()),
              'maximumVertexShiftSvg': float(np.linalg.norm(project(vertices[:, :2]) - project(old_vertices[:, :2]), axis=1).max()),
              'discardedVertexOnlyApproximation': {'maximumSvg': maximum_error, 'countOver0_01Svg': error_count, 'requiresCellSplittingBeforeAdoption': error_count > 0 and not args.split_cells},
              'cellSplitting': cell_report,
              'navigationPartition': nav_proof,
              'markedRays': ray_records,
              'limitations': ['Only two manually confirmed Split structures; not an automatic all-map policy', 'Defense artwork correspondence unverified', 'Header preserves source provenance and must never be accepted as original source; use this candidate manifest to identify modified bytes']}
    if args.warp_file:
        report['controlConstraints'] = {'path': str(args.warp_file.resolve()), 'sha256': sha(args.warp_file.read_bytes())}
        report['ambiguitiesNotChanged'] = ['See the per-map warp candidate review manifest for rejected/uncertain correspondences']
        report['limitations'] = ['Candidate warp requires source and rendered scene review before adoption', 'Header retains original source provenance; candidate manifest identifies changed bytes']
    if cell_report:
        cell_report['navigationCellSplitting'] = 'applied; see navigationPartition proof' if args.split_navigation else 'not applied; navigation interiors remain approximate'
        report['preserved'].remove('face topology/order')
        report['preserved'].append('source triangles partitioned without lost/duplicated area; interpolated alpha UVs retained')
    np.savez_compressed(out / 'warp.npz', points=warp.points, displacements=warp.delta, triangles=warp.tri.simplices)
    (out / 'candidate.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
