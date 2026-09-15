"""Verify authored-facing signs without changing geometry or standing floors.

The sidecar certifies which side of each placed triangle was authored as front.
It does not establish Pawn collision or certify the surface as player support.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path

import numpy as np

from repair_world_material_bindings import correspondence_error


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def authored_facing_signs(local, transform, actual, orientation='rightHanded'):
    """Resolve per-face winding even if import reordered triangle corners."""
    if orientation not in ('rightHanded', 'leftHanded'):
        raise ValueError('Unsupported authored mesh orientation.')
    matrix = transform[:3, :3]
    if abs(np.linalg.det(matrix)) < 1e-12:
        raise ValueError('Singular placement has no inverse-transpose facing.')
    authored = np.cross(local[:, 1] - local[:, 0], local[:, 2] - local[:, 0]) @ np.linalg.inv(matrix).T
    if orientation == 'leftHanded':
        authored *= -1
    geometric = np.cross(actual[:, 1] - actual[:, 0], actual[:, 2] - actual[:, 0])
    lengths = np.linalg.norm(geometric, axis=1)
    authored_lengths = np.linalg.norm(authored, axis=1)
    live = (lengths > 0) & (authored_lengths > 0)
    normal, source_normal = np.zeros_like(geometric), np.zeros_like(authored)
    normal[live] = geometric[live] / lengths[live, None]
    source_normal[live] = authored[live] / authored_lengths[live, None]
    dot = np.einsum('ij,ij->i', normal, source_normal)
    signs = np.where(dot < 0, -1, 1).astype(np.int8)
    # Independently match the complete corner permutation. This catches the
    # rare thin triangle whose float32 perturbation flips its geometric normal
    # even though import preserved the original corner order.
    expected = (local @ matrix + transform[3, :3]) * .01
    permutations = [(0, 1, 2), (0, 2, 1), (1, 0, 2), (1, 2, 0), (2, 0, 1), (2, 1, 0)]
    errors = np.stack([np.sum((actual - expected[:, p]) ** 2, axis=(1, 2)) for p in permutations], axis=1)
    parity = np.asarray([1, -1, -1, 1, 1, -1], dtype=np.int8)[errors.argmin(axis=1)]
    corner_signs = parity * (1 if np.linalg.det(matrix) > 0 else -1) * (1 if orientation == 'rightHanded' else -1)
    return signs, {'live': live, 'normal': normal, 'authoredNormal': source_normal,
                   'absoluteNormalDot': abs(dot),
                   'areaSquareMeters': lengths / 2,
                   'cornerFacingDisagrees': live & (corner_signs != signs),
                   'eligibilityDisagrees': live & ((signs * normal[:, 2] > .65) != (source_normal[:, 2] > .65))}


def derive(world, audit_path, binding_path, output, navigation):
    from pxr import Usd, UsdGeom
    import shapely
    from bake_navigation_floors import plane, clip_halfplane
    world, audit_path, binding_path, output = map(Path, (world, audit_path, binding_path, output))
    if output.resolve() == world.resolve() or world.resolve() in output.resolve().parents:
        raise ValueError('Facing proof must be separate from frozen world input.')
    audit = json.loads(audit_path.read_bytes())
    binding = json.loads(binding_path.read_bytes())
    metadata = json.loads((world / 'geometry.json').read_bytes())
    geometry_sha = digest(world / 'geometry.npz')
    if (not audit['stageReady'] or audit['errors'] or audit['candidateGeometrySha256'] != geometry_sha
            or metadata['geometrySha256'] != geometry_sha or digest(binding['source']) != binding['sourceSha256']
            or audit['sourceUsdSha256'] != binding['sourceSha256']):
        raise ValueError('Source identity or native correspondence audit failed.')
    stage = Usd.Stage.Open(binding['source'])
    cache = UsdGeom.XformCache()
    data = np.load(world / 'geometry.npz')
    points, faces, material_ids = data['points'], data['faces'], data['material_indices']
    floor_material = np.asarray([m['category'] in ('opaque', 'unresolved') for m in metadata['materials']])
    native = json.loads(Path(navigation).read_bytes())
    native_z = np.asarray(native['vertices']).reshape(-1, 3)[:, 2] / 100
    native_window = [float(native_z.min() - .60001), float(native_z.max() + .30001)]
    native_vertices = np.asarray(native['vertices']).reshape(-1,3) / 100
    native_vertices[:,1] *= -1
    native_triangles = native_vertices[np.asarray(native['triangles']).reshape(-1,4)[:,1:]]
    native_shapes = shapely.polygons(native_triangles[:,:,:2])
    native_tree = shapely.STRtree(native_shapes)

    def in_floor_window(triangle):
        shape = shapely.Polygon(triangle[:,:2])
        if shape.area < 1e-8:
            return False
        coefficients = plane(triangle)
        for row in native_tree.query(shape, predicate='intersects'):
            intersection = shape.intersection(native_shapes[row])
            if intersection.geom_type != 'Polygon' or intersection.area < 1e-8:
                continue
            coords = list(intersection.exterior.coords)[:-1]
            delta = coefficients - plane(native_triangles[row])
            coords = clip_halfplane(coords, delta, .30001)
            coords = clip_halfplane(coords, -delta, .60001)
            if len(coords) >= 3 and shapely.Polygon(coords).area >= 1e-8:
                return True
        return False
    signs = np.zeros(len(faces), dtype=np.int8)
    degenerate = []
    singular = []
    tiny_ambiguous = []
    outside_height = []
    outside_domain = []
    disagreements = []
    records = []
    sources = {}
    for placement in audit['placements']:
        first, count = placement['firstFace'], placement['faceCount']
        if first < 0 or first + count > len(faces) or signs[first:first+count].any():
            raise ValueError('Placed face ranges overlap or exceed source geometry.')
        path = placement['sourcePrim']
        if path not in sources:
            prim = stage.GetPrimAtPath(path)
            mesh = UsdGeom.Mesh(prim)
            vertices = np.asarray(mesh.GetPointsAttr().Get(), dtype=float)
            indices = np.asarray(mesh.GetFaceVertexIndicesAttr().Get(), dtype=int).reshape(-1, 3)
            orientation = mesh.GetOrientationAttr().Get()
            if '/Prototypes/' in path:
                instancer = UsdGeom.PointInstancer(stage.GetPrimAtPath(path.split('/Prototypes/')[0]))
                parent = np.asarray(cache.GetLocalToWorldTransform(instancer.GetPrim()))
                transforms = [np.asarray(t) @ parent for t in instancer.ComputeInstanceTransformsAtTime(
                    Usd.TimeCode.Default(), Usd.TimeCode.Default())]
            else:
                transforms = [np.asarray(cache.GetLocalToWorldTransform(prim))]
            sources[path] = vertices, indices, orientation, transforms
        vertices, indices, orientation, transforms = sources[path]
        if len(indices) != count:
            raise ValueError('Source face count differs from native placement proof.')
        transform = transforms[placement['sourceInstance']]
        determinant = float(np.linalg.det(transform[:3, :3]))
        if not np.isclose(determinant, placement['placementDeterminant'], rtol=1e-12, atol=1e-12):
            raise ValueError('Source transform differs from verified native placement.')
        local = vertices[indices]
        expected = (local @ transform[:3, :3] + transform[3, :3]) * .01
        actual = points[faces[first:first+count]].astype(float)
        error = correspondence_error(expected, actual)
        if error > placement['coordinateToleranceMeters']:
            raise ValueError('Placed triangle correspondence changed.')
        row = {'path': placement['path'], 'firstFace': first, 'faceCount': count,
               'sourcePrim': path, 'sourceInstance': placement['sourceInstance'],
               'authoredOrientation': orientation, 'determinant': determinant,
               'coordinateErrorMeters': error}
        if abs(determinant) < 1e-12:
            if floor_material[material_ids[first:first+count]].any():
                raise ValueError('Potential standing floor has singular source transform.')
            signs[first:first+count] = 1
            singular.append({'firstFace': first, 'faceCount': count, 'reason': 'singular-placement-excluded-by-ground-material'})
            row['floorExcludedSingularTransform'] = True
        else:
            facing, proof = authored_facing_signs(local, transform, actual, orientation)
            signs[first:first+count] = facing
            live = proof['live']
            # Low-area source faces can collapse after float32 world export.
            # Their zero cross product cannot satisfy the ground slope test.
            degenerate.extend((np.flatnonzero(~live) + first).tolist())
            ambiguous = live & (proof['absoluteNormalDot'] < .5)
            if ambiguous.any():
                affected = np.flatnonzero(ambiguous)
                large = affected[proof['areaSquareMeters'][affected] >= 1e-8]
                outside = np.asarray([(actual[i,:,2].max() < native_window[0] or
                                       actual[i,:,2].min() > native_window[1]) for i in large], dtype=bool)
                spatial = large[~outside]
                active = [i for i in spatial if in_floor_window(actual[i])]
                if active:
                    raise ValueError('Nondegenerate source facing cannot be matched unambiguously: ' + json.dumps({
                        'path': placement['path'], 'faces': (affected + first).tolist(),
                        'dots': proof['absoluteNormalDot'][affected].tolist(),
                        'areas': proof['areaSquareMeters'][affected].tolist(),
                        'groundMaterial': floor_material[material_ids[first+affected]].tolist()}))
                outside_height.extend({'sourceFace': int(first+i), 'triangleMeters': actual[i].tolist(),
                    'sourceTriangleMeters': expected[i].tolist(), 'areaSquareMeters': float(proof['areaSquareMeters'][i]),
                    'nativeFloorWindowMeters': native_window} for i in large[outside])
                outside_domain.extend({'sourceFace': int(first+i), 'triangleMeters': actual[i].tolist(),
                    'sourceTriangleMeters': expected[i].tolist(), 'areaSquareMeters': float(proof['areaSquareMeters'][i]),
                    'clippedNativeFloorPieces': 0} for i in spatial)
                # These have less total area than the existing floor builder's
                # minimum clipped patch. Float32 perturbation can dominate the
                # normal of a nearly collinear triangle; record the exception.
                tiny_ambiguous.extend({'sourceFace': int(first+i),
                    'areaSquareMeters': float(proof['areaSquareMeters'][i]),
                    'absoluteNormalDot': float(proof['absoluteNormalDot'][i])} for i in affected
                    if proof['areaSquareMeters'][i] < 1e-8)
            differing = np.flatnonzero(proof['eligibilityDisagrees'])
            for i in differing:
                disagreements.append({'sourceFace': int(first+i), 'groundMaterial': bool(floor_material[material_ids[first+i]]),
                    'actualFacingNormalZ': float(facing[i] * proof['normal'][i,2]),
                    'sourceFacingNormalZ': float(proof['authoredNormal'][i,2])})
            row.update(negativeSigns=int((facing < 0).sum()), degenerateFaces=int((~live).sum()),
                       cornerFacingDisagreements=int(proof['cornerFacingDisagrees'].sum()),
                       minimumAbsoluteNormalDot=float(proof['absoluteNormalDot'][live].min()) if live.any() else None)
        records.append(row)
    if (signs == 0).any():
        raise ValueError('Facing proof does not cover every source face.')
    output.mkdir(parents=True, exist_ok=True)
    signs_file = output / 'ground-facing-signs.npz'
    np.savez_compressed(signs_file, facingSigns=signs)
    result = {'schemaVersion': 1, 'map': metadata['map'], 'geometrySha256': geometry_sha,
              'faceCount': len(signs), 'signsFile': signs_file.name, 'signsSha256': digest(signs_file), 'dtype': 'int8',
              'meaning': 'authored-front-normal = geometric-cross * facingSign',
              'sourceUsdSha256': binding['sourceSha256'], 'nativeAuditSha256': digest(audit_path),
              'toolSha256': digest(__file__), 'negativeSigns': int((signs < 0).sum()),
              'degenerateSourceFaces': degenerate, 'groundExcludedSingularRanges': singular,
              'groundExcludedSubthresholdFaces': tiny_ambiguous,
              'groundExcludedOutsideHeightFaces': outside_height, 'nativeFloorWindowMeters': native_window,
              'groundExcludedOutsideDomainFaces': outside_domain, 'sourceNavigationXYZ': str(Path(navigation).resolve()),
              'sourceNavigationXYZSha256': digest(navigation),
              'slopeThresholdDisagreements': disagreements, 'placements': records}
    (output / 'ground-facing.json').write_text(json.dumps(result, separators=(',', ':')))
    print(json.dumps({'map': metadata['map'], 'faces': len(signs), 'negativeSigns': result['negativeSigns'],
                      'degenerate': len(degenerate), 'singularRanges': len(singular),
                      'slopeDisagreements': len(disagreements)}), flush=True)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--world-root', type=Path, required=True)
    parser.add_argument('--verification-root', type=Path, required=True)
    parser.add_argument('--output-root', type=Path, required=True)
    parser.add_argument('--navigation-root', type=Path, required=True)
    parser.add_argument('--maps', nargs='+', required=True)
    args = parser.parse_args()
    for name in args.maps:
        derive(args.world_root / name, args.world_root / name / 'native-slot-audit.json',
               args.verification_root / name / 'materials.json', args.output_root / name,
               args.navigation_root / f'{name}_source_xyz.json')
