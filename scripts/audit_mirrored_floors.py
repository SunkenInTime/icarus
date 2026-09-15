"""Measure selected-floor changes from verified instance handedness alone.

Reads frozen Art, existing observer floors and native placement audit. Material
eligibility and navigation height windows stay unchanged. Every changed face is
clipped to those windows; representative interior probes compare highest floor
surfaces within the same nav parent. No source or floor file is written.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import time

import numpy as np
import shapely

from bake_navigation_floors import clip_halfplane, plane


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def clip_window(triangle, nav_triangle):
    shape = shapely.Polygon(triangle[:, :2]).intersection(shapely.Polygon(nav_triangle[:, :2]))
    if shape.geom_type != 'Polygon' or shape.area < 1e-8:
        return None
    delta = plane(triangle) - plane(nav_triangle)
    points = clip_halfplane(list(shape.exterior.coords)[:-1], delta, .30001)
    points = clip_halfplane(points, -delta, .60001)
    if len(points) < 3:
        return None
    result = shapely.Polygon(points)
    return result if result.area >= 1e-8 else None


def classify_heights(old, corrected, candidate, *, tolerance_meters=.0002):
    if old is None and corrected is None:
        return 'no-selected-surface'
    if old is None:
        return 'newly-covered'
    if corrected is None:
        return 'lost-eligible-coverage'
    if abs(corrected - old) > tolerance_meters:
        return 'selected-height-changed'
    if abs(candidate - old) <= tolerance_meters:
        return 'coincident-selected-height'
    return 'interior-or-occluded'


class SurfaceIndex:
    def __init__(self, xyz, parents=None, source_ids=None):
        self.xyz = xyz
        normals = np.cross(xyz[:, 1] - xyz[:, 0], xyz[:, 2] - xyz[:, 0])
        self.planes = np.column_stack((-normals[:, 0] / normals[:, 2], -normals[:, 1] / normals[:, 2],
                                      np.einsum('ij,ij->i', normals, xyz[:, 0]) / normals[:, 2]))
        self.shapes = shapely.polygons(xyz[:, :, :2])
        self.tree = shapely.STRtree(self.shapes)
        self.parents, self.source_ids = parents, source_ids

    def at(self, point, parent=None):
        ids = self.tree.query(shapely.Point(point), predicate='intersects')
        if parent is not None:
            ids = ids[self.parents[ids] == parent]
        heights = self.planes[ids, :2] @ point + self.planes[ids, 2]
        return ids, heights


def audit(world, navigation_root, orientation_path, output, *, prove_dominated=False):
    started = time.perf_counter()
    world, navigation_root, orientation_path, output = map(Path, (world, navigation_root, orientation_path, output))
    metadata = json.loads((world / 'geometry.json').read_bytes())
    orientation = json.loads(orientation_path.read_bytes())
    fingerprint = digest(world / 'geometry.npz')
    if fingerprint != metadata['geometrySha256'] or fingerprint != orientation['baselineGeometrySha256']:
        raise ValueError('Orientation audit must identify this exact frozen baseline geometry.')
    if orientation.get('errors') or orientation['map'] != metadata['map']:
        raise ValueError('Placement orientation audit is incomplete or refers to another map.')
    nav_path = navigation_root / (metadata['map'] + '_source_xyz.json')
    nav = json.loads(nav_path.read_bytes())
    walking = json.loads((navigation_root / (metadata['map'] + '_navigation.json')).read_bytes())
    floor_path = world / 'floor-mesh.json'
    floor = json.loads(floor_path.read_bytes())
    if floor['sourceXYZSha256'] != digest(nav_path) or floor['navigationSha256'] != nav['navigationSha256']:
        raise ValueError('Observer floor does not match the unchanged navigation windows.')
    with np.load(world / 'geometry.npz') as raw:
        points, faces, material_ids = raw['points'], raw['faces'], raw['material_indices']
    sign = np.zeros(len(faces), dtype=np.int8)
    object_ids = np.full(len(faces), -1, dtype=np.int32)
    solid = np.asarray([record['category'] in ('opaque', 'unresolved') for record in metadata['materials']])[material_ids]
    excluded_singular_faces = 0
    placements = orientation['placements']
    for index, placement in enumerate(placements):
        first, count = placement['firstFace'], placement['faceCount']
        determinant = placement['placementDeterminant']
        if (not np.isfinite(determinant) or first < 0 or first + count > len(faces)
                or np.any(sign[first:first + count]) or placement['coordinateErrorMeters'] > placement['coordinateToleranceMeters']):
            raise ValueError('Invalid, duplicate or unverified orientation face range.')
        if abs(determinant) < 1e-12:
            if np.any(solid[first:first + count]):
                raise ValueError('A singular transform contains potentially admitted floor surfaces.')
            excluded_singular_faces += count
        sign[first:first + count] = 1 if determinant > 0 else -1
        object_ids[first:first + count] = index
    if np.any(sign == 0):
        raise ValueError('Placement orientation does not cover every baseline face.')
    xyz = points[faces]
    normals = np.cross(xyz[:, 1] - xyz[:, 0], xyz[:, 2] - xyz[:, 0])
    lengths = np.linalg.norm(normals, axis=1)
    old_allowed = (normals[:, 2] > .65 * lengths) & solid
    new_allowed = (sign * normals[:, 2] > .65 * lengths) & solid
    changed = np.flatnonzero(old_allowed != new_allowed)
    union_ids = np.flatnonzero(old_allowed | new_allowed)
    source_index = SurfaceIndex(xyz[union_ids], source_ids=union_ids)
    nav_vertices = np.asarray(nav['vertices'], dtype=float).reshape(-1, 3) / 100
    nav_vertices[:, 1] *= -1
    nav_faces = np.asarray(nav['triangles'], dtype=int).reshape(-1, 4)
    walkable = np.asarray(walking['walkable'], dtype=bool)
    nav_faces = nav_faces[walkable[nav_faces[:, 0]]]
    nav_xyz = nav_vertices[nav_faces[:, 1:]]
    nav_index = SurfaceIndex(nav_xyz, nav_faces[:, 0])
    floor_data = floor['floorMesh']
    floor_vertices = np.asarray(floor_data['vertices'], dtype=float).reshape(-1, 3)
    ui, scale = metadata['uiTransform'], floor_data['coordinateScale']
    u, v = floor_vertices[:, 0].copy() / scale, floor_vertices[:, 1].copy() / scale
    floor_vertices[:, 0] = (v - ui['YScalarToAdd']) / (100 * ui['YMultiplier'])
    floor_vertices[:, 1] = -(u - ui['XScalarToAdd']) / (100 * ui['XMultiplier'])
    floor_vertices[:, 2] /= 100
    floor_faces = np.asarray(floor_data['triangles'], dtype=int).reshape(-1, 4)
    floor_index = SurfaceIndex(floor_vertices[floor_faces[:, 1:]], floor_faces[:, 0])
    del normals, lengths, points, faces, floor_vertices
    counters, probe_counts, examples = Counter(), Counter(), {}
    changed_shapes = []
    piece_rows = []
    maximum_change = 0.
    maximum_baseline_disagreement = 0.
    maximum_undominated_area = 0.

    def selected(point, parent):
        source_ids, heights = source_index.at(point)
        nav_ids, nav_heights = nav_index.at(point, parent)
        floor_ids, baked_heights = floor_index.at(point, parent)
        if not len(nav_ids):
            return None
        admitted = np.any((heights[:, None] - nav_heights >= -.60001) &
                          (heights[:, None] - nav_heights <= .30001), axis=1)
        original_ids = source_index.source_ids[source_ids]
        old = heights[admitted & old_allowed[original_ids]]
        new = heights[admitted & new_allowed[original_ids]]
        return (float(baked_heights.max()) if len(baked_heights) else None,
                float(old.max()) if len(old) else None, float(new.max()) if len(new) else None,
                original_ids, heights, admitted)

    for number, face_id in enumerate(changed):
        triangle = xyz[face_id]
        rows = nav_index.tree.query(shapely.Polygon(triangle[:, :2]), predicate='intersects')
        if not len(rows):
            counters['outside-walkable-nav-faces'] += 1
            continue
        kept = 0
        for row in rows:
            parent = int(nav_faces[row, 0])
            piece = clip_window(triangle, nav_xyz[row])
            if piece is None:
                counters['rejected-nav-intersections'] += 1
                continue
            kept += 1
            counters['added-clipped-pieces' if new_allowed[face_id] else 'removed-clipped-pieces'] += 1
            center = np.asarray(piece.representative_point().coords[0])
            probes = [center]
            # Probe within each corner and along each boundary, not on a mesh
            # edge whose quantized inclusion can differ by a few micrometers.
            corners = np.asarray(piece.exterior.coords[:-1])
            probes += [center * .01 + corner * .99 for corner in corners]
            probes += [center * .5 + corner * .5 for corner in corners]
            piece_classes = Counter()
            source_plane = plane(triangle)
            if prove_dominated and new_allowed[face_id]:
                covering = []
                candidates = source_index.tree.query(piece, predicate='intersects')
                for candidate in candidates:
                    original_id = source_index.source_ids[candidate]
                    if not (old_allowed[original_id] and new_allowed[original_id]):
                        continue
                    overlap = source_index.shapes[candidate].intersection(piece)
                    if overlap.geom_type != 'Polygon' or overlap.area < 1e-8:
                        continue
                    coefficients = source_index.planes[candidate]
                    difference = coefficients - plane(nav_xyz[row])
                    polygon = clip_halfplane(list(overlap.exterior.coords)[:-1], difference, .30001)
                    polygon = clip_halfplane(polygon, -difference, .60001)
                    polygon = clip_halfplane(polygon, source_plane - coefficients, .0002)
                    if len(polygon) >= 3:
                        covering.append(shapely.Polygon(polygon))
                residual_area = piece.difference(shapely.union_all(covering)).area
                maximum_undominated_area = max(maximum_undominated_area, residual_area)
                counters['added-pieces-dominated-within-0.02cm' if residual_area < 1e-8 else 'added-pieces-with-unproven-remainder'] += 1
            for point in probes:
                result = selected(point, parent)
                if result is None:
                    probe_counts['numerically-outside-parent'] += 1
                    continue
                baked, old, new, source_ids, heights, admitted = result
                if old is not None and baked is not None:
                    maximum_baseline_disagreement = max(maximum_baseline_disagreement, abs(old - baked))
                # The analytic old selection distinguishes current floor-mesh
                # coverage/quantization from the effect of correcting winding.
                candidate_height = float(source_plane[:2] @ point + source_plane[2])
                classification = classify_heights(old, new, candidate_height)
                probe_counts[classification] += 1
                piece_classes[classification] += 1
                if classification in ('selected-height-changed', 'newly-covered', 'lost-eligible-coverage'):
                    maximum_change = max(maximum_change, abs(old - new) if old is not None and new is not None else 0)
                    example_key = (int(face_id), parent, classification)
                    prior = examples.get(example_key)
                    difference = abs(old - new) if old is not None and new is not None else 0
                    if prior is None or difference > prior['heightDifferenceMeters']:
                        placement = placements[int(object_ids[face_id])]
                        top_ids = source_ids[admitted & new_allowed[source_ids] & (abs(heights - new) < .00001)] if new is not None else []
                        examples[example_key] = {'classification': classification, 'sourceFace': int(face_id),
                            'heightDifferenceMeters': difference,
                            'object': placement['path'], 'placementDeterminant': placement['placementDeterminant'],
                            'parentNavPolygon': parent, 'worldXYMeters': point.tolist(),
                            'uv': [-point[1] * 100 * ui['XMultiplier'] + ui['XScalarToAdd'],
                                   point[0] * 100 * ui['YMultiplier'] + ui['YScalarToAdd']],
                            'currentFloorMeshCm': None if baked is None else baked * 100,
                            'oldAnalyticFloorCm': None if old is None else old * 100,
                            'correctedAnalyticFloorCm': None if new is None else new * 100,
                            'correctedSelectedFaces': [int(value) for value in top_ids[:8]],
                            'becameEligible': bool(new_allowed[face_id])}
            if any(piece_classes[key] for key in ('selected-height-changed', 'newly-covered', 'lost-eligible-coverage')):
                changed_shapes.append(piece)
            piece_rows.append({'sourceFace': int(face_id), 'parentNavPolygon': parent, 'areaSquareMeters': piece.area,
                               'becameEligible': bool(new_allowed[face_id]), 'probeClasses': dict(piece_classes)})
        if not kept:
            counters['outside-height-window-or-negligible-area-faces'] += 1
        if number % 10000 == 0:
            print(json.dumps({'map': metadata['map'], 'changedFaceProgress': number, 'changedFaces': len(changed)}), flush=True)
    result = {'schemaVersion': 1, 'map': metadata['map'], 'status': 'read-only-handedness-floor-comparison',
              'gameplayCertified': False, 'source': {'geometrySha256': fingerprint,
                 'metadataSha256': digest(world / 'geometry.json'), 'orientationAuditSha256': digest(orientation_path),
                 'floorMeshSha256': digest(floor_path), 'navigationXYZSha256': digest(nav_path), 'scriptSha256': digest(__file__)},
              'summary': {'mirroredPlacements': sum(row['placementDeterminant'] < 0 for row in placements),
                  'singularFacesExcludedByExistingMaterialPolicy': excluded_singular_faces,
                  'changedEligibleFaces': len(changed), 'addedEligibleFaces': int(np.count_nonzero(new_allowed & ~old_allowed)),
                  'removedEligibleFaces': int(np.count_nonzero(old_allowed & ~new_allowed)), **dict(counters),
                  'probeClasses': dict(probe_counts), 'maximumSelectedHeightChangeCm': maximum_change * 100,
                  'maximumBaselineMeshDisagreementCm': maximum_baseline_disagreement * 100,
                  'dominationProofRequested': prove_dominated,
                  'maximumUndominatedPieceAreaSquareMeters': maximum_undominated_area if prove_dominated else None,
                  'unionAreaOfPiecesWithDemonstratedChangesSquareMeters': shapely.union_all(changed_shapes).area if changed_shapes else 0,
                  'seconds': time.perf_counter() - started},
              'examples': sorted(examples.values(), key=lambda row: -row['heightDifferenceMeters']), 'pieces': piece_rows,
              'limitations': ['Interior probes demonstrate changes but do not measure their exact area or prove no change between probes.',
                  'Union area includes entire clipped pieces containing a changed probe; it is an upper bound for that sampled support.',
                  'Material classifications stay at the frozen baseline, independently of later native-slot repairs.',
                  'Missing corrected source coverage is reported separately; runtime fallback after a rebake is not assumed.']}
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2, allow_nan=False), encoding='utf-8')
    print(json.dumps({'map': metadata['map'], **result['summary']}), flush=True)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('world', type=Path)
    parser.add_argument('navigation_root', type=Path)
    parser.add_argument('orientation_audit', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--prove-dominated', action='store_true')
    args = parser.parse_args()
    audit(args.world, args.navigation_root, args.orientation_audit, args.output, prove_dominated=args.prove_dominated)
