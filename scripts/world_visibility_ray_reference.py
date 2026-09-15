"""Independent 3D reference rays for baked standing visibility.

The launcher resolves material policy with the normal audit Python. Blender
casts the original placed triangles, and this module samples alpha at each hit.
It does not call the horizontal section cutter or consume its visibility edges.
"""
import argparse
import bisect
from collections import Counter, OrderedDict
from dataclasses import dataclass
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys
import time
from typing import Callable

import numpy as np


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def sample_alpha(alpha, uv, policy):
    """Independent bilinear sample, with an image whose first row is bottom."""
    if not np.isfinite(uv).all():
        raise ValueError('nonfinite-hit-uv')
    h, w = alpha.shape
    u, v = map(float, uv)
    if ((policy['wrapS'] == 'black' and not 0 <= u <= 1)
            or (policy['wrapT'] == 'black' and not 0 <= v <= 1)):
        return float(policy.get('alphaBias', 0))
    x, y = u * w - .5, v * h - .5
    ix, iy = math.floor(x), math.floor(y)
    fx, fy = x - ix, y - iy

    def pixel(index, size, mode):
        if mode == 'repeat':
            return index % size
        if mode == 'clamp':
            return max(0, min(size - 1, index))
        if mode == 'mirror':
            index %= size * 2
            return index if index < size else size * 2 - 1 - index
        if mode == 'black':
            return index if 0 <= index < size else None
        raise ValueError('unknown-hit-alpha-wrap')

    value = 0.0
    for xx, weight_x in [(ix, 1 - fx), (ix + 1, fx)]:
        px = pixel(xx, w, policy['wrapS'])
        for yy, weight_y in [(iy, 1 - fy), (iy + 1, fy)]:
            py = pixel(yy, h, policy['wrapT'])
            if px is not None and py is not None:
                value += float(alpha[py, px]) * weight_x * weight_y
    return value * policy.get('alphaScale', 1) + policy.get('alphaBias', 0)


def ray_triangle(origin, direction, triangle):
    """Moller-Trumbore used to check coincident faces after a masked hit."""
    edge_a, edge_b = triangle[1] - triangle[0], triangle[2] - triangle[0]
    p = np.cross(direction, edge_b)
    determinant = float(np.dot(edge_a, p))
    if abs(determinant) < 1e-12:
        return None
    relative = origin - triangle[0]
    u = float(np.dot(relative, p)) / determinant
    q = np.cross(relative, edge_a)
    v = float(np.dot(direction, q)) / determinant
    distance = float(np.dot(edge_b, q)) / determinant
    if distance < 0 or u < -1e-7 or v < -1e-7 or u + v > 1 + 1e-7:
        return None
    return distance, (1 - u - v, u, v)


def nearest_elevation(elevations, target):
    """Match the runtime's lower-plane tie break without consuming its code."""
    right = bisect.bisect_left(elevations, target)
    if right == 0:
        return elevations[0]
    if right == len(elevations):
        return elevations[-1]
    low, high = elevations[right - 1], elevations[right]
    return low if target - low <= high - target else high


def heldout_origins(floor_mesh, ui, count, seed, walkable=None):
    vertices = np.asarray(floor_mesh['vertices'], dtype=float).reshape(-1, 3)
    triangles = np.asarray(floor_mesh['triangles'], dtype=np.int64).reshape(-1, 4)
    xyz = vertices.copy()
    scale = floor_mesh['coordinateScale']
    u, v = vertices[:, 0] / scale, vertices[:, 1] / scale
    xyz[:, 0] = (v - ui['YScalarToAdd']) / (ui['YMultiplier'] * 100)
    xyz[:, 1] = -(u - ui['XScalarToAdd']) / (ui['XMultiplier'] * 100)
    xyz[:, 2] /= 100
    corners = xyz[triangles[:, 1:]]
    low_xy, high_xy = corners[:, :, :2].min(axis=1), corners[:, :, :2].max(axis=1)
    areas = np.linalg.norm(np.cross(corners[:, 1] - corners[:, 0],
                                    corners[:, 2] - corners[:, 0]), axis=1) / 2
    valid = np.flatnonzero(areas > 1e-7)
    if walkable is not None:
        valid = valid[np.asarray(walkable, dtype=bool)[triangles[valid, 0]]]
    if not len(valid):
        raise ValueError('No floor area available for independent references.')
    sloped = valid[np.ptp(corners[valid, :, 2], axis=1) > .01]
    random = np.random.default_rng(seed)
    z_buckets = {}
    for index in valid:
        z_buckets.setdefault(round(float(corners[index, :, 2].mean()) * 100), []).append(index)
    rows = []
    for index in range(count):
        if index % 4 == 0 and len(sloped):
            triangle_id = int(random.choice(sloped))
            kind = 'slope'
        elif index % 4 == 1:
            bucket = sorted(z_buckets)[int(random.integers(len(z_buckets)))]
            triangle_id = int(random.choice(z_buckets[bucket]))
            kind = 'height-stratified'
        else:
            triangle_id = int(random.choice(valid, p=areas[valid] / areas[valid].sum()))
            kind = 'area-weighted'
        # Interior random barycentric points are distinct from source vertices
        # and from the centroids used in the floor build's own smoke checks.
        weights = random.random(3) + .2
        weights /= weights.sum()
        point = weights @ corners[triangle_id]
        parent = int(triangles[triangle_id, 0])
        # The floor source can contain overlapping admitted meshes. Standing
        # uses the highest surface within one navigation polygon. Different
        # stacked navigation polygons remain separate floor alternatives.
        possible = np.flatnonzero(np.all(low_xy <= point[:2] + 1e-9, axis=1)
                                  & np.all(high_xy >= point[:2] - 1e-9, axis=1))
        faces = corners[possible]
        edge_a, edge_b = faces[:, 1, :2] - faces[:, 0, :2], faces[:, 2, :2] - faces[:, 0, :2]
        relative = point[:2] - faces[:, 0, :2]
        determinant = edge_a[:, 0] * edge_b[:, 1] - edge_a[:, 1] * edge_b[:, 0]
        with np.errstate(divide='ignore', invalid='ignore'):
            wa = (relative[:, 0] * edge_b[:, 1] - relative[:, 1] * edge_b[:, 0]) / determinant
            wb = (edge_a[:, 0] * relative[:, 1] - edge_a[:, 1] * relative[:, 0]) / determinant
        admitted = (np.abs(determinant) > 1e-12) & (wa >= -1e-7) & (wb >= -1e-7) & (wa + wb <= 1 + 1e-7)
        if walkable is not None:
            admitted &= np.asarray(walkable, dtype=bool)[triangles[possible, 0]]
        heights = faces[:, 0, 2] + wa * (faces[:, 1, 2] - faces[:, 0, 2]) + wb * (faces[:, 2, 2] - faces[:, 0, 2])
        alternatives = {}
        for face_id, height in zip(possible[admitted], heights[admitted]):
            candidate_parent = int(triangles[face_id, 0])
            if candidate_parent not in alternatives or height > alternatives[candidate_parent][0]:
                alternatives[candidate_parent] = float(height), int(face_id)
        if parent not in alternatives:
            raise ValueError('Sampled floor triangle did not contain its own interior.')
        point[2], selected_triangle = alternatives[parent]
        rows.append({'id': index, 'positionMeters': point.tolist(),
                     'parentNavPolygon': parent, 'selectedFloorTriangle': selected_triangle,
                     'sourceFloorTriangle': triangle_id, 'barycentric': weights.tolist(),
                     'floorAlternatives': [{'parentNavPolygon': p, 'floorHeightCm': h * 100,
                                            'sourceFloorTriangle': f}
                                           for p, (h, f) in sorted(alternatives.items())],
                     'sampling': kind})
    return rows


@dataclass(frozen=True)
class ReferenceScene:
    metadata: dict
    floor_report: dict
    policy_document: dict
    geometry_sha256: str
    cast: Callable
    ground_cast: Callable
    diagnostics: Callable


def validate_reference_lineage(metadata, floor_report, geometry_sha256, floor_sha256):
    """Accept a base floor only with an explicit, hash-checked scenery addition."""
    if geometry_sha256 != metadata['geometrySha256']:
        raise ValueError('World reference fingerprint disagrees with its metadata.')
    if geometry_sha256 == floor_report['geometrySha256']:
        return
    proof = metadata.get('supplementation', {})
    preserved = proof.get('floorFilesPreservedSha256', {})
    if (metadata.get('status') != 'corrected-art-with-approved-static-scenery'
            or not metadata.get('supplementGeometrySha256')
            or metadata.get('baseGeometrySha256') != floor_report['geometrySha256']
            or proof.get('baseArtValuesPreservedExactly') is not True
            or preserved.get('floor-mesh.json') != floor_sha256):
        raise ValueError('World and floor reference fingerprints disagree.')


def _clip_halfspace(polygon, values):
    """Clip a convex 3D polygon by a linear signed-distance predicate."""
    result = []
    for i, point in enumerate(polygon):
        previous, value, previous_value = polygon[i - 1], values[i], values[i - 1]
        if (value >= 0) != (previous_value >= 0):
            fraction = previous_value / (previous_value - value)
            result.append(previous + fraction * (point - previous))
        if value >= 0:
            result.append(point)
    return np.asarray(result, dtype=float).reshape(-1, 3)


def native_floor_overlap_area(triangle, native_triangle):
    """Independently clip one source face into a native floor-height prism.

    This reference uses successive 3D half-spaces, without calling the floor
    baker or consuming its clipped polygons. Return projected floor area.
    """
    polygon = np.asarray(triangle, dtype=float)
    native_triangle = np.asarray(native_triangle, dtype=float)
    normal = np.cross(native_triangle[1] - native_triangle[0],
                      native_triangle[2] - native_triangle[0])
    if normal[2] == 0:
        return 0.0
    winding = 1 if normal[2] > 0 else -1
    for a, b in zip(native_triangle, np.roll(native_triangle, -1, axis=0)):
        relative, edge = polygon - a, b - a
        values = winding * (edge[0] * relative[:, 1] - edge[1] * relative[:, 0])
        polygon = _clip_halfspace(polygon, values)
        if len(polygon) < 3:
            return 0.0
    for limit, sign in [(-.60001, 1), (.30001, -1)]:
        # Dot / normalZ equals sourceZ minus nativeZ at the same XY.
        difference = (polygon - native_triangle[0]) @ normal / normal[2]
        polygon = _clip_halfspace(polygon, (difference - limit) * sign)
        if len(polygon) < 3:
            return 0.0
    relative = polygon - polygon[0]
    return abs(float(np.sum(relative[:, 0] * np.roll(relative[:, 1], -1)
                            - relative[:, 1] * np.roll(relative[:, 0], -1)))) / 2


def _load_ground_exclusion_navigation(sidecar, floor_report, *, with_parents=False):
    path = sidecar.get('sourceNavigationXYZ')
    if not isinstance(path, str) or not path:
        raise ValueError('Ground exclusions require an exact native navigation source.')
    source_hash = digest(path)
    if (source_hash != sidecar.get('sourceNavigationXYZSha256')
            or source_hash != floor_report.get('sourceXYZSha256')):
        raise ValueError('Ground exclusion navigation fingerprint mismatch.')
    source = json.loads(Path(path).read_bytes())
    if (source.get('schemaVersion') != 1 or source.get('map') != sidecar.get('map')
            or source.get('coordinates') != 'Unreal XYZ centimetres'
            or source.get('navigationSha256') != floor_report.get('navigationSha256')):
        raise ValueError('Ground exclusion navigation schema or lineage mismatch.')
    vertices = np.asarray(source['vertices'], dtype=float).reshape(-1, 3) / 100
    vertices[:, 1] *= -1
    raw_triangles = np.asarray(source['triangles'])
    if raw_triangles.dtype.kind not in 'iu':
        raise ValueError('Native navigation triangle indices must be integers.')
    triangles = raw_triangles.reshape(-1, 4)[:, 1:]
    if (not len(triangles) or not np.isfinite(vertices).all()
            or triangles.min() < 0 or triangles.max() >= len(vertices)):
        raise ValueError('Native navigation triangles are invalid.')
    result = vertices[triangles]
    return (result, raw_triangles.reshape(-1, 4)[:, 0]) if with_parents else result


def ground_facing_exclusions(sidecar, points, faces, material_ids, materials, face_count,
                             *, native_triangles=None):
    """Check that declared numerical exceptions cannot create a floor patch."""
    excluded, counts = set(), {}

    def face_id(value):
        if type(value) is not int or not 0 <= value < face_count:
            raise ValueError('Ground-facing exclusion has an invalid source face.')
        return value

    def require_subthreshold(index):
        triangle = points[faces[index]].astype(float)
        area = np.linalg.norm(np.cross(triangle[1] - triangle[0], triangle[2] - triangle[0])) / 2
        if not math.isfinite(area) or area > np.nextafter(1e-8, math.inf):
            raise ValueError('A ground-facing numerical exclusion could create a floor patch.')

    tiny = sidecar.get('groundExcludedSubthresholdFaces', [])
    for record in tiny:
        index = face_id(record.get('sourceFace'))
        area = record.get('areaSquareMeters')
        if type(area) not in (float, int) or not math.isfinite(area) or not 0 <= area <= 1e-8:
            raise ValueError('Ground-facing subthreshold proof has an invalid area.')
        require_subthreshold(index)
        excluded.add(index)
    counts['subthresholdFaces'] = len(tiny)
    degenerate = sidecar.get('degenerateSourceFaces', [])
    for value in degenerate:
        index = face_id(value)
        require_subthreshold(index)
        excluded.add(index)
    counts['degenerateFaces'] = len(degenerate)
    singular_count = 0
    for record in sidecar.get('groundExcludedSingularRanges', []):
        first, count = record.get('firstFace'), record.get('faceCount')
        if (type(first) is not int or type(count) is not int or first < 0
                or count < 0 or first + count > face_count):
            raise ValueError('Ground-facing singular range is invalid.')
        indices = range(first, first + count)
        if any(materials[int(material_ids[i])]['category'] in ('opaque', 'unresolved') for i in indices):
            raise ValueError('A singular transform exclusion contains a ground-eligible material.')
        excluded.update(indices)
        singular_count += count
    counts['singularFaces'] = singular_count
    outside_height = sidecar.get('groundExcludedOutsideHeightFaces', [])
    outside_domain = sidecar.get('groundExcludedOutsideDomainFaces', [])
    if outside_height or outside_domain:
        if native_triangles is None:
            raise ValueError('Ground domain exclusions require verified native navigation.')
        low = native_triangles[:, :, 2].min() - .60001
        high = native_triangles[:, :, 2].max() + .30001
        native_low = native_triangles[:, :, :2].min(axis=1)
        native_high = native_triangles[:, :, :2].max(axis=1)
        for record in outside_height + outside_domain:
            index = face_id(record.get('sourceFace'))
            triangle = points[faces[index]].astype(float)
            recorded = np.asarray(record.get('triangleMeters'), dtype=float)
            if recorded.shape != (3, 3) or not np.array_equal(recorded, triangle):
                raise ValueError('Ground domain proof does not match the source triangle.')
            if record in outside_height:
                if not (triangle[:, 2].max() < low or triangle[:, 2].min() > high):
                    raise ValueError('A ground height exclusion overlaps the native floor window.')
            else:
                possible = np.flatnonzero(
                    np.all(native_low <= triangle[:, :2].max(axis=0), axis=1)
                    & np.all(native_high >= triangle[:, :2].min(axis=0), axis=1))
                if any(native_floor_overlap_area(triangle, native_triangles[n]) > 1e-8 for n in possible):
                    raise ValueError('A ground domain exclusion could create a native floor patch.')
            excluded.add(index)
    counts['outsideHeightFaces'] = len(outside_height)
    counts['outsideDomainFaces'] = len(outside_domain)
    return sorted(excluded), counts


def load_ground_facing(folder, metadata, floor_report, geometry_sha256, face_count, *, source_arrays=None):
    """Validate authored-facing evidence without changing the sight geometry.

    Combined worlds retain the Art floor contract. Their sidecar therefore
    covers only the verified Art prefix; supplemental scenery stays visible
    to sight rays but does not silently become a new standing surface.
    """
    descriptor = metadata.get('groundFacing')
    expected = floor_report.get('groundFacingSha256')
    if descriptor is None:
        if expected is not None:
            raise ValueError('Floor facing evidence is missing from world metadata.')
        return None, {'mode': 'legacy-geometric-winding', 'faceCount': face_count,
                      'excludedSupplementalFaces': 0}
    if not isinstance(descriptor, dict) or not expected:
        raise ValueError('Authored-facing metadata and floor proof must agree.')

    def local_file(name):
        if not isinstance(name, str) or not name or Path(name).name != name or name in ('.', '..'):
            raise ValueError('Ground-facing sidecars must use local filenames.')
        path = Path(folder) / name
        if path.resolve().parent != Path(folder).resolve():
            raise ValueError('Ground-facing sidecar escapes its source folder.')
        return path

    sidecar_path = local_file(descriptor.get('file'))
    sidecar_sha = digest(sidecar_path)
    if sidecar_sha != descriptor.get('sha256') or sidecar_sha != expected:
        raise ValueError('Ground-facing sidecar fingerprint disagrees with its floor proof.')
    sidecar = json.loads(sidecar_path.read_bytes())
    if (type(sidecar.get('schemaVersion')) is not int or sidecar['schemaVersion'] != 1
            or sidecar.get('map') != metadata.get('map') or sidecar.get('dtype') != 'int8'
            or sidecar.get('meaning') != 'authored-front-normal = geometric-cross * facingSign'):
        raise ValueError('Unsupported ground-facing sidecar schema.')
    count = sidecar.get('faceCount')
    if type(count) is not int or not 0 <= count <= face_count:
        raise ValueError('Ground-facing face count is invalid.')
    if sidecar.get('geometrySha256') == geometry_sha256:
        if count != face_count or floor_report.get('geometrySha256') != geometry_sha256:
            raise ValueError('A direct ground-facing sidecar must cover every source face.')
        scope = 'full-world'
    else:
        proof = metadata.get('supplementation', {})
        if (descriptor.get('scope') != 'base-art'
                or metadata.get('status') != 'corrected-art-with-approved-static-scenery'
                or sidecar.get('geometrySha256') != metadata.get('baseGeometrySha256')
                or sidecar.get('geometrySha256') != floor_report.get('geometrySha256')
                or proof.get('baseArtValuesPreservedExactly') is not True
                or type(proof.get('baseArtFaceCount')) is not int
                or proof['baseArtFaceCount'] != count):
            raise ValueError('Ground-facing Art prefix lacks verified composition evidence.')
        scope = 'base-art'
    signs_path = local_file(sidecar.get('signsFile'))
    signs_sha = digest(signs_path)
    if signs_sha != sidecar.get('signsSha256'):
        raise ValueError('Ground-facing sign array fingerprint mismatch.')
    with np.load(signs_path, allow_pickle=False) as stored:
        if stored.files != ['facingSigns']:
            raise ValueError('Ground-facing archive must contain only facingSigns.')
        signs = stored['facingSigns']
    if signs.dtype != np.dtype('int8') or signs.shape != (count,) or not np.isin(signs, [-1, 1]).all():
        raise ValueError('Ground-facing signs must be one int8 +1 or -1 per source face.')
    excluded, exclusion_counts = [], {}
    if any(sidecar.get(key) for key in ('groundExcludedSubthresholdFaces', 'degenerateSourceFaces',
                                       'groundExcludedSingularRanges', 'groundExcludedOutsideHeightFaces',
                                       'groundExcludedOutsideDomainFaces')):
        if source_arrays is None:
            raise ValueError('Ground-facing exclusions require their original source geometry.')
        native_triangles = None
        if sidecar.get('groundExcludedOutsideHeightFaces') or sidecar.get('groundExcludedOutsideDomainFaces'):
            native_triangles = _load_ground_exclusion_navigation(sidecar, floor_report)
        excluded, exclusion_counts = ground_facing_exclusions(
            sidecar, *source_arrays, metadata['materials'], count, native_triangles=native_triangles)
    return signs, {'mode': 'authored-source-facing', 'scope': scope, 'faceCount': count,
                   'sidecarSha256': sidecar_sha, 'signsSha256': signs_sha,
                   'excludedSourceFaces': excluded, 'numericalExclusions': exclusion_counts,
                   'excludedSupplementalFaces': face_count - count}


def load_ground_support(folder, metadata, floor_report, geometry_sha256, face_count, facing_info):
    """Apply only source-supported floor changes to an otherwise frozen floor."""
    descriptor, expected = metadata.get('groundSupport'), floor_report.get('groundSupportSha256')
    if descriptor is None:
        if expected is not None:
            raise ValueError('Ground support evidence is missing from world metadata.')
        return None, {'mode': 'no-selective-support-sidecar'}
    if not isinstance(descriptor, dict) or not expected or facing_info['mode'] != 'authored-source-facing':
        raise ValueError('Selective ground support requires matching floor and facing evidence.')

    def local_file(name):
        if not isinstance(name, str) or not name or Path(name).name != name or name in ('.', '..'):
            raise ValueError('Ground support evidence must use local filenames.')
        path = Path(folder) / name
        if path.resolve().parent != Path(folder).resolve():
            raise ValueError('Ground support evidence escapes its source folder.')
        return path

    path = local_file(descriptor.get('file'))
    fingerprint = digest(path)
    if fingerprint != descriptor.get('sha256') or fingerprint != expected:
        raise ValueError('Ground support fingerprint disagrees with its floor proof.')
    support = json.loads(path.read_bytes())
    count = facing_info['faceCount']
    if (type(support.get('schemaVersion')) is not int or support['schemaVersion'] != 1
            or support.get('map') != metadata.get('map')
            or support.get('defaultMode') != 'baseline-geometric-winding'
            or support.get('baselinePointsDtype') != 'float32'
            or type(support.get('faceCount')) is not int or support['faceCount'] != count
            or support.get('geometrySha256') != floor_report.get('geometrySha256')
            or (count != face_count and descriptor.get('scope') != 'base-art')):
        raise ValueError('Unsupported ground support schema or source scope.')
    proof_path = local_file(support.get('sourceProofFile'))
    proof_sha = digest(proof_path)
    if proof_sha != support.get('sourceProofSha256'):
        raise ValueError('Native ground support source proof fingerprint mismatch.')
    proof = json.loads(proof_path.read_bytes())
    if proof.get('schemaVersion') != 1 or proof.get('status') != 'native-pawn-support-evidence':
        raise ValueError('Unsupported native ground support evidence schema.')
    matches = [v for v in proof.get('maps', []) if v.get('map') == metadata.get('map')]
    if len(matches) != 1 or matches[0].get('nativeCandidateGeometrySha256') != support['geometrySha256']:
        raise ValueError('Native ground support proof refers to another source world.')
    records = {(v['firstFace'], v['faceCount']): v for v in matches[0]['placements']}
    authored, excluded = np.zeros(count, dtype=bool), np.zeros(count, dtype=bool)
    for key, mask, classification in [
        ('authoredFacingRanges', authored, 'declared-pawn-blocking-complex'),
        ('excludedRanges', excluded, 'excluded-explicit-pawn-nonblocking'),
    ]:
        for record in support.get(key, []):
            first, size = record.get('firstFace'), record.get('faceCount')
            if (type(first) is not int or type(size) is not int or first < 0 or size <= 0
                    or first + size > count or not record.get('reason') or not record.get('sourceRecordId')):
                raise ValueError('Selective ground support range is invalid.')
            source_record = records.get((first, size))
            if (source_record is None or source_record.get('classification') != classification
                    or record['sourceRecordId'] != f"{support['map']}:{first}"):
                raise ValueError('Selective ground support range lacks its native source evidence.')
            if np.any(authored[first:first + size] | excluded[first:first + size]):
                raise ValueError('Selective ground support ranges overlap.')
            mask[first:first + size] = True
    support['_authoredMask'], support['_excludedMask'] = authored, excluded
    support['_folder'] = Path(folder)
    support['_sourceMap'] = matches[0]
    return support, {'mode': 'selective-source-supported-ground', 'sidecarSha256': fingerprint,
                     'sourceProofSha256': proof_sha, 'baselinePointsDtype': 'float32',
                     'authoredFacingFaces': int(authored.sum()), 'excludedFaces': int(excluded.sum()),
                     'overrideFloorMeshes': len(support.get('overrideFloorMeshes', []))}


def load_ground_overrides(support, floor_report, points, faces):
    """Load separately proven collision hulls used only for standing ground."""
    if support is None or not support.get('overrideFloorMeshes'):
        return []
    native_triangles, native_parents = _load_ground_exclusion_navigation(
        support, floor_report, with_parents=True)
    result = []
    for entry in support['overrideFloorMeshes']:
        paths = []
        for file_key, hash_key in [('file', 'sha256'), ('sourceProofFile', 'sourceProofSha256')]:
            name = entry.get(file_key)
            if not isinstance(name, str) or not name or Path(name).name != name or name in ('.', '..'):
                raise ValueError('Ground override must use local source filenames.')
            path = support['_folder'] / name
            if path.resolve().parent != support['_folder'].resolve() or digest(path) != entry.get(hash_key):
                raise ValueError('Ground override source fingerprint or path mismatch.')
            paths.append(path)
        with np.load(paths[0], allow_pickle=False) as stored:
            if set(stored.files) != {'points', 'faces'}:
                raise ValueError('Ground override archive must contain only points and faces.')
            patch_points, patch_faces = stored['points'], stored['faces']
        proof = json.loads(paths[1].read_bytes())
        if (proof.get('map') != support['map'] or proof.get('floorPatchSha256') != entry['sha256']
                or proof.get('sourceCollisionEnabled') != 'ECollisionEnabled::QueryAndPhysics'
                or proof.get('sourceRestOffset') != 0):
            raise ValueError('Ground override lacks the supported native hull contract.')
        if (patch_points.dtype.kind != 'f' or patch_points.ndim != 2 or patch_points.shape[1] != 3
                or not np.isfinite(patch_points).all() or patch_faces.dtype.kind not in 'iu'
                or patch_faces.ndim != 2 or patch_faces.shape[1] != 3 or not len(patch_faces)
                or patch_faces.min() < 0 or patch_faces.max() >= len(patch_points)):
            raise ValueError('Ground override geometry is invalid.')
        # Replay the native convex vertices and corner order, independently of
        # the clipped floor artifact. The source proof binds the placed matrix.
        mesh_path = Path(proof['sourceMesh'])
        placement_path = Path(proof['nativePlacementFile'])
        if digest(mesh_path) != proof['sourceMeshSha256'] or digest(placement_path) != proof['nativePlacementSha256']:
            raise ValueError('Ground override native source evidence changed.')
        mesh = json.loads(mesh_path.read_bytes())
        setups = [o for o in mesh if o.get('Type') == 'BodySetup']
        if len(setups) != 1:
            raise ValueError('Ground override native body setup is ambiguous.')
        convex = setups[0]['Properties']['AggGeom']['ConvexElems'][proof['sourceConvexElement']]
        local_transform = convex.get('Transform', {})
        if (convex.get('CollisionEnabled') != proof['sourceCollisionEnabled']
                or convex.get('RestOffset') != 0
                or any(local_transform.get('Translation', {}).get(k) != 0 for k in ('X', 'Y', 'Z'))
                or any(local_transform.get('Scale3D', {}).get(k) != 1 for k in ('X', 'Y', 'Z'))
                or any(local_transform.get('Rotation', {}).get(k) != 0 for k in ('X', 'Y', 'Z'))
                or local_transform.get('Rotation', {}).get('W') != 1):
            raise ValueError('Ground override native hull uses an unhandled local transform or collision mode.')
        original = np.asarray([[v[axis] for axis in ('X', 'Y', 'Z')] for v in convex['VertexData']], dtype=float)
        original[:, 1] *= -1
        matrix = np.asarray(proof['worldTransformUSDRowMatrix'], dtype=float)
        if matrix.shape != (4, 4) or not np.isfinite(matrix).all():
            raise ValueError('Ground override world transform is invalid.')
        original = (original @ matrix[:3, :3] + matrix[3, :3]) * .01
        original_faces = np.asarray(convex['IndexData'], dtype=np.int64).reshape(-1, 3)
        corners = original[original_faces]
        normals = np.cross(corners[:, 1] - corners[:, 0], corners[:, 2] - corners[:, 0])
        inward = np.einsum('ij,ij->i', normals, corners.mean(axis=1) - original.mean(axis=0)) < 0
        original_faces[inward] = original_faces[inward][:, [0, 2, 1]]
        if not np.array_equal(original, patch_points) or not np.array_equal(original_faces, patch_faces):
            raise ValueError('Ground override differs from its placed native convex hull.')
        scope, parents = entry.get('scopeArtFaces'), entry.get('parentNavPolygons')
        if (not isinstance(scope, list) or not scope or any(type(i) is not int or not 0 <= i < support['faceCount'] for i in scope)
                or not isinstance(parents, list) or not parents or any(type(p) is not int or p < 0 for p in parents)):
            raise ValueError('Ground override scope is invalid.')
        allowed_faces, allowed_parents = set(), set()
        for record in support['_sourceMap']['placements']:
            if any(record['firstFace'] <= i < record['firstFace'] + record['faceCount'] for i in scope):
                allowed_faces.update(record['facingChangedFacesInFloorWindows'])
                allowed_parents.update(record['parentNavPolygons'])
        if not set(scope) <= allowed_faces or not set(parents) <= allowed_parents:
            raise ValueError('Ground override scope exceeds its audited source footprint.')
        corners = patch_points[patch_faces].astype(float)
        normals = np.cross(corners[:, 1] - corners[:, 0], corners[:, 2] - corners[:, 0])
        upward = normals[:, 2] > .65 * np.linalg.norm(normals, axis=1)
        scope_corners = points[faces[scope]].astype(float)
        selection = np.isin(native_parents, parents)
        result.append({'entry': entry, 'corners': corners[upward], 'nativeFaceIds': np.flatnonzero(upward),
                       'scopeCorners': scope_corners, 'nativeCorners': native_triangles[selection],
                       'nativeParents': native_parents[selection]})
    return result


def _column_heights(triangles, xy):
    """Exact double vertical intersections and source-local face IDs."""
    a, b = triangles[:, 1, :2] - triangles[:, 0, :2], triangles[:, 2, :2] - triangles[:, 0, :2]
    relative = xy - triangles[:, 0, :2]
    determinant = a[:, 0] * b[:, 1] - a[:, 1] * b[:, 0]
    with np.errstate(divide='ignore', invalid='ignore'):
        u = (relative[:, 0] * b[:, 1] - relative[:, 1] * b[:, 0]) / determinant
        v = (a[:, 0] * relative[:, 1] - a[:, 1] * relative[:, 0]) / determinant
        heights = triangles[:, 0, 2] + u * (triangles[:, 1, 2] - triangles[:, 0, 2]) + v * (triangles[:, 2, 2] - triangles[:, 0, 2])
    indices = np.flatnonzero((determinant != 0) & (u >= -1e-10) & (v >= -1e-10) & (u + v <= 1 + 1e-10))
    return indices, heights[indices]


def ground_override_cast(overrides, origin, direction, distance, parent_nav_polygon):
    """Replace baseline ground only where a proven hull backs the scoped floor."""
    if not overrides:
        return None
    if parent_nav_polygon is None:
        raise ValueError('Ground overrides require the observer native navigation parent.')
    if tuple(direction) != (0, 0, -1):
        raise ValueError('Scoped ground overrides support vertical downward references only.')
    origin = np.asarray(origin, dtype=float)
    candidates = []
    for override in overrides:
        native = override['nativeCorners'][override['nativeParents'] == parent_nav_polygon]
        _, nav_z = _column_heights(native, origin[:2])
        _, scope_z = _column_heights(override['scopeCorners'], origin[:2])
        if not len(nav_z) or not len(scope_z):
            continue
        if not any(np.any((scope_z - z >= -.60001) & (scope_z - z <= .30001)) for z in nav_z):
            continue
        face_ids, hull_z = _column_heights(override['corners'], origin[:2])
        for index, height in zip(face_ids, hull_z):
            if np.any((height - nav_z >= -.60001) & (height - nav_z <= .30001)):
                candidates.append((float(height), override, int(index)))
    if not candidates:
        return None
    height, override, index = max(candidates, key=lambda v: v[0])
    hit_distance = float(origin[2] - height)
    hit = {'distanceMeters': distance, 'hitMeters': None, 'materialCertain': True,
           'groundEligibility': 'scoped-native-convex-floor',
           'groundOverrideFile': override['entry']['file'],
           'nativeHullFace': int(override['nativeFaceIds'][index]),
           'referencePrecision': 'float64-native-hull'}
    if 0 <= hit_distance <= distance:
        triangle = override['corners'][index]
        normal = np.cross(triangle[1] - triangle[0], triangle[2] - triangle[0])
        normal /= np.linalg.norm(normal)
        hit.update(distanceMeters=hit_distance, hitMeters=[float(origin[0]), float(origin[1]), height],
                   normal=normal.tolist())
    return hit


def eligible_ground_faces(points, faces, material_ids, materials, facing_signs=None, excluded_faces=(),
                          support=None):
    """Select upward source surfaces, independently of the clipped floor mesh."""
    count = len(faces) if facing_signs is None else len(facing_signs)
    xyz = points[faces[:count]]
    if support is not None:
        xyz = xyz.astype(np.float32)
    elif facing_signs is not None:
        # A combined world may promote an unchanged Art prefix to float64.
        # V3 defines slope eligibility in float64 for both source forms.
        xyz = xyz.astype(np.float64)
    normals = np.cross(xyz[:, 1] - xyz[:, 0], xyz[:, 2] - xyz[:, 0])
    if facing_signs is not None and support is None:
        normals *= facing_signs[:, None]
    eligible_material = np.array([m['category'] in ('opaque', 'unresolved') for m in materials])
    eligible = ((normals[:, 2] > .65 * np.linalg.norm(normals, axis=1))
                & eligible_material[material_ids[:count]])
    if support is not None:
        selected = np.flatnonzero(support['_authoredMask'])
        xyz = points[faces[selected]].astype(np.float64)
        corrected = np.cross(xyz[:, 1] - xyz[:, 0], xyz[:, 2] - xyz[:, 0])
        corrected *= facing_signs[selected, None]
        eligible[selected] = ((corrected[:, 2] > .65 * np.linalg.norm(corrected, axis=1))
                              & eligible_material[material_ids[selected]])
        eligible[support['_excludedMask']] = False
    if len(excluded_faces):
        eligible[np.asarray(excluded_faces, dtype=np.int64)] = False
    return np.flatnonzero(eligible)


def load_reference_scene(world_folder, policy_path):
    """Load the independent 3D caster once for exports or height calibration."""
    import bpy
    from mathutils import Vector
    from mathutils.bvhtree import BVHTree

    folder = Path(world_folder)
    metadata = json.loads((folder / 'geometry.json').read_text(encoding='utf-8'))
    floor_report = json.loads((folder / 'floor-mesh.json').read_text(encoding='utf-8'))
    fingerprint = digest(folder / 'geometry.npz')
    validate_reference_lineage(metadata, floor_report, fingerprint,
                               digest(folder / 'floor-mesh.json'))
    policy_document = json.loads(Path(policy_path).read_text(encoding='utf-8'))
    policies = policy_document['policies']
    if policy_document['navigationSha256'] != floor_report['navigationSha256']:
        raise ValueError('Navigation walkability and floor fingerprints disagree.')
    source = np.load(folder / 'geometry.npz')
    points, source_faces = source['points'], source['faces']
    texture_uvs, material_ids = source['uvs'], source['material_indices']
    ground_facing, ground_facing_info = load_ground_facing(
        folder, metadata, floor_report, fingerprint, len(source_faces),
        source_arrays=(points, source_faces, material_ids))
    ground_excluded_faces = ground_facing_info.pop('excludedSourceFaces', [])
    ground_support, ground_support_info = load_ground_support(
        folder, metadata, floor_report, fingerprint, len(source_faces), ground_facing_info)
    ground_overrides = load_ground_overrides(ground_support, floor_report, points, source_faces)
    ground_native_triangles = ground_native_parents = None
    if ground_support is not None:
        ground_native_triangles, ground_native_parents = _load_ground_exclusion_navigation(
            ground_support, floor_report, with_parents=True)
    keep = np.array([p['mode'] != 'ignore' for p in policies])[material_ids]
    face_ids = np.flatnonzero(keep)
    faces = source_faces[keep]
    tree = BVHTree.FromPolygons(points.tolist(), faces.tolist(), all_triangles=True, epsilon=0)
    image_cache, sampling_errors = OrderedDict(), Counter()

    def alpha_image(policy):
        path = policy['alphaTexture']
        if path in image_cache:
            value = image_cache.pop(path)
            image_cache[path] = value
            return value
        if digest(path) != policy['alphaTextureSha256']:
            raise ValueError('hit-alpha-image-hash-mismatch')
        image = bpy.data.images.load(path, check_existing=False)
        try:
            w, h = image.size
            pixels = np.empty(w * h * 4, dtype=np.float32)
            image.pixels.foreach_get(pixels)
            value = pixels.reshape(h, w, 4)[:, :, 3].copy()
        finally:
            bpy.data.images.remove(image)
        image_cache[path] = value
        if len(image_cache) > 8:
            image_cache.popitem(last=False)
        return value

    def material_at_hit(source_face, position):
        source_face = int(source_face)
        material_id = int(material_ids[source_face])
        policy = policies[material_id]
        result = {'sourceFace': source_face, 'material': material_id,
                  'materialMode': policy['mode'], 'materialCertain': policy['certain']}
        if policy['mode'] != 'alpha-test':
            return True, result
        tri = points[source_faces[source_face]]
        a, b, relative = tri[1] - tri[0], tri[2] - tri[0], np.asarray(position) - tri[0]
        aa, ab, bb = np.dot(a, a), np.dot(a, b), np.dot(b, b)
        denominator = aa * bb - ab * ab
        try:
            if abs(denominator) < 1e-18:
                raise ValueError('degenerate-hit-triangle')
            ar, br = np.dot(a, relative), np.dot(b, relative)
            weight_b, weight_c = (bb * ar - ab * br) / denominator, (aa * br - ab * ar) / denominator
            uv = np.array([1 - weight_b - weight_c, weight_b, weight_c]) @ texture_uvs[source_face]
            alpha = sample_alpha(alpha_image(policy), uv, policy)
            result.update(alpha=alpha, textureUv=uv.tolist())
            return alpha >= policy['threshold'], result
        except (OSError, ValueError, RuntimeError) as error:
            reason = str(error)
            sampling_errors[reason] += 1
            result.update(materialCertain=False, alphaError=reason)
            return True, result

    object_bounds = np.asarray([o['boundsMeters'] for o in metadata['objects']])
    precision_fallbacks = 0

    def precise_cast(origin, direction, distance):
        """Double-precision fallback when float32 BVH repeats a masked face."""
        nonlocal precision_fallbacks
        precision_fallbacks += 1
        origin, direction = np.asarray(origin, dtype=float), np.asarray(direction, dtype=float)
        end = origin + direction * distance
        low, high = np.minimum(origin, end) - 1e-7, np.maximum(origin, end) + 1e-7
        object_ids = np.flatnonzero(np.all(object_bounds[:, 1] >= low, axis=1)
                                   & np.all(object_bounds[:, 0] <= high, axis=1))
        candidates = np.concatenate([np.arange(metadata['objects'][i]['firstFace'],
            metadata['objects'][i]['firstFace'] + metadata['objects'][i]['faceCount']) for i in object_ids])
        candidates = candidates[keep[candidates]]
        tri = points[source_faces[candidates]].astype(float)
        a, b = tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0]
        p = np.cross(direction, b)
        determinant = np.einsum('ij,ij->i', a, p)
        relative = origin - tri[:, 0]
        q = np.cross(relative, a)
        with np.errstate(divide='ignore', invalid='ignore'):
            u = np.einsum('ij,ij->i', relative, p) / determinant
            v = np.einsum('j,ij->i', direction, q) / determinant
            t = np.einsum('ij,ij->i', b, q) / determinant
            valid = np.flatnonzero((np.abs(determinant) > 1e-12) & (t >= 0) & (t <= distance)
                                  & (u >= -1e-7) & (v >= -1e-7) & (u + v <= 1 + 1e-7))
        skipped = 0
        for i in valid[np.argsort(t[valid])]:
            hit = origin + direction * t[i]
            blocks, info = material_at_hit(candidates[i], hit)
            if blocks:
                normal = np.cross(a[i], b[i]); normal /= np.linalg.norm(normal)
                return {'distanceMeters': float(t[i]), 'hitMeters': hit.tolist(),
                        'normal': normal.tolist(), 'transparentHitsSkipped': skipped,
                        'precisionFallback': True, **info}
            skipped += 1
        return {'distanceMeters': distance, 'hitMeters': None, 'precisionFallback': True,
                'transparentHitsSkipped': skipped, 'materialCertain': True}

    def cast(origin, direction, distance):
        original, direction = Vector(origin), Vector(direction)
        current = original.copy()
        skips = 0
        visited_faces = set()
        for iteration in range(256):
            remaining = distance - (current - original).length
            if remaining <= 0:
                break
            position, normal, face, _ = tree.ray_cast(current, direction, remaining)
            if face is None:
                break
            if face in visited_faces:
                return precise_cast(original, direction, distance)
            visited_faces.add(face)
            blocks, info = material_at_hit(face_ids[face], position)
            hit_distance = (position - original).length
            if not blocks:
                # A masked decal can lie directly on an opaque wall. A small
                # forward step alone would skip that wall, so check neighbors.
                for _, _, neighbor, _ in tree.find_nearest_range(position, .00002):
                    if neighbor == face:
                        continue
                    source_id = face_ids[neighbor]
                    intersection = ray_triangle(np.asarray(original), np.asarray(direction), points[source_faces[source_id]])
                    if intersection is None or abs(intersection[0] - hit_distance) > .00003:
                        continue
                    hit = original + direction * intersection[0]
                    blocks, info = material_at_hit(face_ids[neighbor], hit)
                    if blocks:
                        position, hit_distance = hit, intersection[0]
                        break
            if blocks:
                return {'distanceMeters': hit_distance, 'hitMeters': list(position),
                        'normal': list(normal), 'transparentHitsSkipped': skips,
                        **info}
            skips += 1
            # Blender's BVH uses float32 positions. A fixed 1e-7 meter step can
            # round back to the same hit far from world origin. Advance by the
            # next representable coordinate, after checking coincident faces.
            coordinates = np.asarray(position, dtype=np.float32)
            step = max(1e-7, float(np.max(np.abs(np.spacing(coordinates)))) * 2)
            current = original + direction * (hit_distance + step)
        else:
            return precise_cast(original, direction, distance)
        return {'distanceMeters': distance, 'hitMeters': None,
                'transparentHitsSkipped': skips, 'materialCertain': True}

    floor_tree, floor_faces = None, None
    ground_precision_attempts = ground_precision_fallbacks = 0
    ground_window_rejections = 0

    def ground_cast(origin, direction, distance, parent_nav_polygon=None):
        """Check ground against the floor builder's eligible source surfaces."""
        nonlocal floor_tree, floor_faces, ground_precision_attempts, ground_precision_fallbacks, ground_window_rejections
        override = ground_override_cast(ground_overrides, origin, direction, distance, parent_nav_polygon)
        if override is not None:
            return override
        nav_heights = None
        if ground_native_triangles is not None:
            if parent_nav_polygon is None:
                raise ValueError('Selective ground references require their native navigation parent.')
            native = ground_native_triangles[ground_native_parents == parent_nav_polygon]
            _, nav_heights = _column_heights(native, np.asarray(origin)[:2])
            if not len(nav_heights):
                raise ValueError('Ground origin does not lie inside its stated native navigation parent.')

        def admitted_height(height):
            return nav_heights is None or np.any((height - nav_heights >= -.60001)
                                                 & (height - nav_heights <= .30001))
        if floor_tree is None:
            floor_faces = eligible_ground_faces(points, source_faces, material_ids,
                                                metadata['materials'], ground_facing, ground_excluded_faces,
                                                ground_support)
            # Compact the BVH vertex table so checking ground does not require
            # a second Python list of every decorative scene vertex.
            vertex_ids, indices = np.unique(source_faces[floor_faces], return_inverse=True)
            floor_tree = BVHTree.FromPolygons(points[vertex_ids].tolist(), indices.reshape(-1, 3).tolist(),
                                              all_triangles=True, epsilon=0)
        position, normal, face, hit_distance = floor_tree.ray_cast(Vector(origin), Vector(direction), distance)
        precision = 'float32-bvh'
        window_rejected = face is not None and not admitted_height(position[2])
        if window_rejected:
            ground_window_rejections += 1
        if face is None or window_rejected:
            # Clipped floor slivers can put the original double-precision
            # origin inside an edge while Blender rounds it outside. Query a
            # sphere covering the entire short ray, then intersect only those
            # eligible source triangles with the original double coordinates.
            ground_precision_attempts += 1
            exact_origin = np.asarray(origin, dtype=float)
            exact_direction = np.asarray(direction, dtype=float)
            midpoint = exact_origin + exact_direction * (distance / 2)
            margin = max(.00002, float(np.max(np.abs(np.spacing(midpoint.astype(np.float32))))) * 4)
            nearest = None
            for _, _, candidate, _ in floor_tree.find_nearest_range(Vector(midpoint), distance / 2 + margin):
                triangle = points[source_faces[floor_faces[candidate]]].astype(float)
                intersection = ray_triangle(exact_origin, exact_direction, triangle)
                if (intersection is None or intersection[0] > distance
                        or min(intersection[1]) < -1e-10
                        or not admitted_height(exact_origin[2] + exact_direction[2] * intersection[0])):
                    continue
                if nearest is None or intersection[0] < nearest[0]:
                    nearest = intersection[0], candidate, triangle
            if nearest is None:
                return {'distanceMeters': distance, 'hitMeters': None, 'materialCertain': True,
                        'groundPrecisionFallbackAttempted': True}
            hit_distance, face, triangle = nearest
            position = exact_origin + exact_direction * hit_distance
            normal = np.cross(triangle[1] - triangle[0], triangle[2] - triangle[0])
            normal /= np.linalg.norm(normal)
            precision = 'float64-native-window-fallback' if window_rejected else 'float64-edge-fallback'
            ground_precision_fallbacks += 1
        source_face = int(floor_faces[face])
        material_id = int(material_ids[source_face])
        facing_sign = int(ground_facing[source_face]) if ground_facing is not None else 1
        ground_mode = ground_facing_info['mode']
        if ground_support is not None and not ground_support['_authoredMask'][source_face]:
            facing_sign = 1
            ground_mode = 'preserved-baseline-float32-ground'
        elif ground_support is not None:
            ground_mode = 'native-supported-authored-facing-float64-ground'
        normal = np.asarray(normal) * facing_sign
        return {'distanceMeters': float(hit_distance), 'hitMeters': list(map(float, position)),
                'normal': list(map(float, normal)),
                'sourceFace': source_face, 'material': material_id,
                'referencePrecision': precision,
                'materialCertain': metadata['materials'][material_id]['category'] == 'opaque',
                'groundFacingSign': facing_sign,
                'groundEligibility': ground_mode + '; normalZ>0.65*length; opaque-or-unresolved-source-material'}

    def diagnostics():
        return {'alphaSamplingErrors': dict(sampling_errors),
                'doublePrecisionFallbacks': precision_fallbacks,
                'groundDoublePrecisionAttempts': ground_precision_attempts,
                'groundDoublePrecisionFallbacks': ground_precision_fallbacks,
                'groundNativeWindowRejections': ground_window_rejections,
                'groundFacing': ground_facing_info,
                'groundSupport': ground_support_info,
                'eligibleGroundFaces': len(floor_faces) if floor_faces is not None else 0}

    return ReferenceScene(metadata, floor_report, policy_document, fingerprint, cast, ground_cast, diagnostics)


def blender_reference(args):
    import bpy

    started = time.perf_counter()
    folder = Path(args.world)
    scene = load_reference_scene(folder, args.policies)
    metadata, floor_report = scene.metadata, scene.floor_report
    policy_document, fingerprint, cast = scene.policy_document, scene.geometry_sha256, scene.cast
    ui = metadata['uiTransform']
    elevations = None
    if args.elevations_file:
        elevations = json.loads(Path(args.elevations_file).read_text(encoding='utf-8'))
        if (not elevations or not all(isinstance(v, (int, float)) and math.isfinite(v) for v in elevations)
                or elevations != sorted(set(elevations))):
            raise ValueError('Reference elevations must be finite, increasing and nonempty.')
    def to_uv(point):
        return [-point[1] * 100 * ui['XMultiplier'] + ui['XScalarToAdd'],
                point[0] * 100 * ui['YMultiplier'] + ui['YScalarToAdd']]

    origins = heldout_origins(floor_report['floorMesh'], ui, args.samples, args.seed,
                             policy_document['walkable'])
    rays = []
    for sample in origins:
        origin = np.asarray(sample['positionMeters'])
        # Ground uses the floor builder's upward opaque/unresolved predicate.
        # Sight-material downward hits remain a separate diagnostic.
        floor_hit = scene.ground_cast(origin + (0, 0, .02), (0, 0, -1), .04,
                                      parent_nav_polygon=sample['parentNavPolygon'])
        sample['floorCheck'] = floor_hit
        sample['floorAgreesWithin1Cm'] = bool(floor_hit['hitMeters'] is not None and
            abs(floor_hit['hitMeters'][2] - origin[2]) <= .01)
        sample['genericSightFloorCheck'] = cast(origin + (0, 0, .02), (0, 0, -1), .04)
        origin = origin + (0, 0, args.eye_height_cm / 100)
        plane_height = nearest_elevation(elevations, origin[2] * 100) if elevations else None
        for ray_index in range(args.directions):
            angle = (ray_index + args.direction_phase) * math.tau / args.directions
            direction = np.array([math.cos(angle), math.sin(angle), 0])
            end = origin + direction * args.range_meters
            row = {'id': f"{sample['id']}-{ray_index}", 'sample': sample['id'],
                         'heightAboveFloorMeters': args.eye_height_cm / 100,
                         'startMeters': origin.tolist(), 'endMeters': end.tolist(),
                         'startUv': to_uv(origin), 'endUv': to_uv(end),
                   **cast(origin, direction, args.range_meters)}
            if plane_height is not None:
                plane_origin = np.array([origin[0], origin[1], plane_height / 100])
                row['planeElevationCm'] = plane_height
                row['planeReference'] = cast(plane_origin, direction, args.range_meters)
            rays.append(row)
        if sample['id'] % 64 == 0:
            print(json.dumps({'map': metadata['map'], 'samples': sample['id'] + 1,
                              'rays': len(rays), 'seconds': time.perf_counter() - started}), flush=True)
    result = {'schemaVersion': 1, 'map': metadata['map'],
              'status': 'independent-material-aware-3d-reference', 'gameplayCertified': False,
              'eyeHeightCm': args.eye_height_cm, 'rangeMeters': args.range_meters,
              'sampling': {'seed': args.seed, 'directions': args.directions, 'directionPhase': args.direction_phase},
              'source': {'geometrySha256': fingerprint, 'metadataSha256': digest(folder / 'geometry.json'),
                         'floorMeshSha256': digest(folder / 'floor-mesh.json'),
                         'materialPoliciesSha256': digest(args.policies),
                         'navigationSha256': policy_document['navigationSha256'],
                         'referenceScriptSha256': digest(__file__),
                         'groundFacing': scene.diagnostics()['groundFacing'],
                         'groundSupport': scene.diagnostics()['groundSupport'],
                         'elevationsSha256': digest(args.elevations_file) if args.elevations_file else None,
                         'bpyVersion': bpy.app.version_string},
              'origins': origins, 'rays': rays,
              'summary': {'origins': len(origins), 'rays': len(rays),
                          'floorAgreement': sum(o['floorAgreesWithin1Cm'] for o in origins),
                          'alphaSamplingErrors': scene.diagnostics()['alphaSamplingErrors'],
                          'uncertainBlockedRays': sum(r['hitMeters'] is not None and not r['materialCertain'] for r in rays),
                          'transparentHitsSkipped': sum(r['transparentHitsSkipped'] for r in rays),
                          'doublePrecisionFallbacks': scene.diagnostics()['doublePrecisionFallbacks'],
                          'groundDoublePrecisionAttempts': scene.diagnostics()['groundDoublePrecisionAttempts'],
                          'groundDoublePrecisionFallbacks': scene.diagnostics()['groundDoublePrecisionFallbacks'],
                          'seconds': time.perf_counter() - started},
              'limitations': ['Static selected Art scene; dynamic state is not simulated.',
                              'Full-size texture alpha with exported wrap policy; native mip/shader differences remain.',
                              'Standing horizontal sightlines only.',
                              'Independent cast verifies this source scene, not complete in-game behavior.']}
    pending = Path(args.output).with_suffix('.writing')
    pending.write_text(json.dumps(result, separators=(',', ':')), encoding='utf-8')
    pending.replace(args.output)
    print(json.dumps(result['summary']), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--world', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--blender')
    parser.add_argument('--samples', type=int, default=256)
    parser.add_argument('--directions', type=int, default=32)
    parser.add_argument('--range-meters', type=float, default=50)
    parser.add_argument('--eye-height-cm', type=float, default=175)
    parser.add_argument('--seed', type=int, default=120783)
    parser.add_argument('--direction-phase', type=float, default=.371)
    parser.add_argument('--elevations-file')
    parser.add_argument('--texture-properties-root')
    parser.add_argument('--policies')
    parser.add_argument('--navigation')
    parser.add_argument('--inside-blender', action='store_true')
    arguments = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else sys.argv[1:]
    args = parser.parse_args(arguments)
    if (args.samples <= 0 or args.directions < 4 or args.range_meters <= 0 or args.eye_height_cm <= 0
            or not all(math.isfinite(v) for v in (args.range_meters, args.eye_height_cm, args.direction_phase))
            or not 0 <= args.direction_phase < 1 or args.seed < 0):
        parser.error('Positive origin/range/height values and at least four directions are required.')
    if args.inside_blender:
        blender_reference(args)
        return
    if not args.blender:
        parser.error('--blender is required for the launcher')
    from world_visibility_materials import build_policy
    metadata = json.loads((Path(args.world) / 'geometry.json').read_text(encoding='utf-8'))
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    policy_path = output.with_suffix('.policies.json')
    navigation_path = Path(args.navigation) if args.navigation else (
        Path(args.world).parent.parent / 'nav' / 'baked' / (metadata['map'] + '_navigation.json'))
    navigation = json.loads(navigation_path.read_text(encoding='utf-8'))
    policy_path.write_text(json.dumps({'walkable': navigation['walkable'],
        'navigationSha256': digest(navigation_path), 'policies': [build_policy(m,
        texture_properties_root=args.texture_properties_root) for m in metadata['materials']]}), encoding='utf-8')
    command = [str(Path(args.blender).resolve()), '--background', '--factory-startup', '--python-exit-code', '1', '--python', str(Path(__file__).resolve()), '--',
               '--inside-blender', '--world', args.world, '--output', args.output,
               '--policies', str(policy_path), '--samples', str(args.samples),
               '--directions', str(args.directions), '--range-meters', str(args.range_meters),
               '--eye-height-cm', str(args.eye_height_cm), '--seed', str(args.seed),
               '--direction-phase', str(args.direction_phase)]
    if args.elevations_file:
        command.extend(('--elevations-file', args.elevations_file))
    subprocess.run(command, check=True)
    if not output.is_file():
        raise RuntimeError('Blender returned without writing reference rays.')


if __name__ == '__main__':
    main()
