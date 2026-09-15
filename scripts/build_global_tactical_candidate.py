"""Split source faces at every ground-field boundary before transforming Z."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import time
import numpy as np
import shapely
from audit_tactical_target_rays import ReferenceModel
from experimental_floor_relative_visibility import FloorPatch, clip_face_to_patch
from tactical_pack_writer import write_pack


class GroundField:
    def __init__(self, path):
        self.bytes = Path(path).read_bytes()
        self.data = json.loads(gzip.decompress(self.bytes))
        self.vertices = np.array(self.data['vertices']).reshape(-1, 3)
        self.triangles = np.array(self.data['triangles']).reshape(-1, 3)
        points = self.vertices[self.triangles]
        self.planes = np.linalg.solve(np.concatenate([points[:, :, :2], np.ones((len(points), 3, 1))], 2), points[:, :, 2, None])[:, :, 0]
        self.polygons = shapely.polygons(points[:, :, :2])
        self.tree = shapely.STRtree(self.polygons)
        self.patches = [FloorPatch(p[:, :2], plane) for p, plane in zip(points, self.planes)]
        _, self.plane_ids = np.unique(np.round(self.planes, 8), axis=0, return_inverse=True)

    def locate(self, xy, allow_outside=False):
        xy = np.asarray(xy)
        result = np.full(len(xy), -1, dtype=np.int32)
        for start in range(0, len(xy), 100000):
            rows = xy[start:start + 100000]
            point_ids, cells = self.tree.query(shapely.points(rows), predicate='intersects')
            result[start + point_ids] = cells
        missing = np.flatnonzero(result < 0)
        if len(missing) and not allow_outside:
            raise ValueError(f'{len(missing)} points outside ground field')
        return result

    def heights(self, xy):
        cells = self.locate(xy)
        return np.sum(self.planes[cells, :2] * xy, axis=1) + self.planes[cells, 2]


def build(pack, field_path, output):
    started = time.perf_counter()
    source = ReferenceModel(pack)
    field = GroundField(field_path)
    observer_domain = source.header.get('originalObserverHeightDomainMeters', source.header.get('heightDomainProof', {}).get('originalObserverHeightDomainMeters', source.header['heightDomainMeters']))
    field_domain = [float(field.vertices[:, 2].min()), float(field.vertices[:, 2].max())]
    relative_domain = [observer_domain[0] - field_domain[1], observer_domain[1] - field_domain[0]]
    source_domain = [relative_domain[0] + field_domain[0], relative_domain[1] + field_domain[1]]
    original_points, all_faces = source.arrays['vertices'], source.arrays['faces']
    field_bounds = field.data['bounds']
    eligible = []
    for start in range(0, len(all_faces), 100000):
        ids = np.arange(start, min(start + 100000, len(all_faces)))
        points = original_points[all_faces[ids]]
        minimum, maximum = points.min(1), points.max(1)
        keep = (minimum[:, 2] <= source_domain[1]) & (maximum[:, 2] >= source_domain[0])
        keep &= np.all(maximum[:, :2] >= field_bounds[:2], axis=1) & np.all(minimum[:, :2] <= field_bounds[2:], axis=1)
        eligible.extend(ids[keep])
    eligible = np.array(eligible)
    original_faces = all_faces[eligible]
    used, compact = np.unique(original_faces, return_inverse=True)
    original_faces = compact.reshape(-1, 3)
    original_points = original_points[used]
    cells = field.locate(original_points[:, :2], allow_outside=True)
    vertex_planes = field.plane_ids[cells]
    face_planes = vertex_planes[original_faces]
    # Equal planes at all corners alone is insufficient: a big triangle may
    # cross an island of different ground inside it. The candidate test below
    # therefore checks every field-cell bounding box for each source face.
    triangles = original_points[original_faces]
    lower, upper = triangles[:, :, :2].min(1), triangles[:, :, :2].max(1)
    # Each field cell is convex: if all corners occupy one cell, the complete
    # source triangle lies in it. Different cells are clipped even when their
    # planes match, because a third plane may occupy their interior.
    face_cells = cells[original_faces]
    potentially_crossing = np.any(face_cells != face_cells[:, :1], axis=1)
    potentially_crossing |= np.any(face_cells < 0, axis=1)
    # Find cells intersecting the actual projected face (a line for a vertical
    # wall), not just its bounding box. Adjacent coplanar cells need no cuts.
    pending = np.flatnonzero(potentially_crossing)
    candidate_face_rows, candidate_regions = [], []
    maximum_fast_path_error = 0.
    fast_path_faces = 0
    for start in range(0, len(pending), 25000):
        ids = pending[start:start + 25000]
        shapes = shapely.convex_hull(shapely.multipoints(triangles[ids, :, :2]))
        rows, regions = field.tree.query(shapes, predicate='intersects')
        reference_planes = field.planes[cells[original_faces[ids]]]
        reference = np.sum(reference_planes[:, :, :2] * triangles[ids, :, :2], axis=2) + reference_planes[:, :, 2]
        predicted = np.einsum('ni,nji->nj', field.planes[regions, :2], triangles[ids[rows], :, :2]) + field.planes[regions, 2, None]
        errors = np.max(np.abs(predicted - reference[rows]), axis=1)
        maximum_error = np.zeros(len(ids))
        np.maximum.at(maximum_error, rows, errors)
        fast = (maximum_error <= 1e-11) & np.all(face_cells[ids] >= 0, axis=1)
        maximum_fast_path_error = max(maximum_fast_path_error, float(maximum_error[fast].max(initial=0)))
        fast_path_faces += int(fast.sum())
        potentially_crossing[ids[fast]] = False
        selected = ~fast[rows]
        candidate_face_rows.extend(ids[rows[selected]])
        candidate_regions.extend(regions[selected])
    candidate_face_rows, candidate_regions = np.array(candidate_face_rows), np.array(candidate_regions)
    order = np.argsort(candidate_face_rows, kind='stable')
    candidate_regions = candidate_regions[order]
    candidate_offsets = np.r_[0, np.cumsum(np.bincount(candidate_face_rows, minlength=len(original_faces)))]
    unchanged = np.flatnonzero(~potentially_crossing)
    crossing = np.flatnonzero(potentially_crossing)
    print(f'{len(unchanged)} unchanged-plane faces, {len(crossing)} potentially crossing', flush=True)
    flat_points = original_points.copy()
    flat_points[:, 2] -= np.sum(field.planes[cells, :2] * flat_points[:, :2], axis=1) + field.planes[cells, 2]
    added_points, added_faces, added_source, added_uvs, added_materials = [], [], [], [], []
    additional_masks = []
    maximum_inverse_error = 0.
    covered = np.zeros(len(original_faces), dtype=bool)
    coverage_ratios = np.zeros(len(original_faces), dtype=float)
    expected_ratios = np.ones(len(original_faces), dtype=float)
    covered[unchanged] = True
    coverage_ratios[unchanged] = 1
    rectangle = np.array([[field_bounds[0], field_bounds[1]], [field_bounds[2], field_bounds[1]],
                          [field_bounds[2], field_bounds[3]], [field_bounds[0], field_bounds[3]]])
    rectangle_patch = FloorPatch(rectangle, np.array([0., 0., 0.]))
    outside_faces = np.flatnonzero(np.any(face_cells < 0, axis=1))
    for index in outside_faces:
        pieces = clip_face_to_patch(triangles[index], rectangle_patch)
        expected_ratios[index] = sum(abs(float(np.linalg.det(np.array([pieces[0][3:], pieces[i][3:], pieces[i + 1][3:]]))))
                                     for i in range(1, len(pieces) - 1))
    for index, source_id in enumerate(crossing):
        original = triangles[source_id]
        candidates = candidate_regions[candidate_offsets[source_id]:candidate_offsets[source_id + 1]]
        seen = set()
        for region in candidates:
            patch = field.patches[region]
            pieces = clip_face_to_patch(original, patch)
            for piece_index in range(1, len(pieces) - 1):
                piece = np.array([pieces[0], pieces[piece_index], pieces[piece_index + 1]])
                weights = piece[:, 3:]
                transformed = piece[:, :3].copy()
                transformed[:, 2] -= patch.height(transformed[:, :2])
                if np.linalg.norm(np.cross(transformed[1] - transformed[0], transformed[2] - transformed[0])) < 1e-12:
                    continue
                key = tuple(sorted(tuple(row) for row in np.round(weights, 10)))
                if key in seen:
                    continue
                seen.add(key)
                coverage_ratios[source_id] += abs(float(np.linalg.det(weights)))
                inverse = transformed.copy()
                inverse[:, 2] += patch.height(transformed[:, :2])
                maximum_inverse_error = max(maximum_inverse_error, float(np.abs(inverse - weights @ original).max()))
                offset = len(original_points) + len(added_points)
                added_points.extend(transformed)
                added_faces.append([offset, offset + 1, offset + 2])
                added_source.append(source_id)
                covered[source_id] = True
                mask = source.arrays['faceMasks'][eligible[source_id]]
                if mask >= 0:
                    additional_masks.append(len(added_uvs))
                    added_uvs.append(weights @ source.arrays['maskedUvs'][mask])
                    added_materials.append(source.arrays['maskedMaterials'][mask])
                else:
                    additional_masks.append(-1)
        if index and index % 10000 == 0:
            print(f'Clipped {index}/{len(crossing)} faces; {time.perf_counter() - started:.1f}s', flush=True)
    missing = np.flatnonzero(~covered)
    if len(missing):
        normal = np.linalg.norm(np.cross(triangles[missing, 1] - triangles[missing, 0], triangles[missing, 2] - triangles[missing, 0]), axis=1)
        if np.any(normal * expected_ratios[missing] > 1e-10):
            raise ValueError(f'{len(missing)} source faces missing, maxarea {normal.max()}')
    source_areas = np.linalg.norm(np.cross(triangles[:, 1] - triangles[:, 0], triangles[:, 2] - triangles[:, 0]), axis=1) / 2
    errors = np.abs(coverage_ratios - expected_ratios) * source_areas
    if errors.max(initial=0) > 1e-7:
        worst = int(np.argmax(errors))
        raise ValueError(f'Incorrect area partition for sourceface {worst}: ratio{coverage_ratios[worst]}, areaerror{errors[worst]}m²')
    points = np.vstack([flat_points, np.array(added_points).reshape(-1, 3)])
    faces = np.vstack([original_faces[unchanged], np.array(added_faces).reshape(-1, 3)])
    original_masks = source.arrays['faceMasks'][eligible[unchanged]]
    masked_ids = np.flatnonzero(original_masks >= 0)
    masks = np.full(len(faces), -1, dtype=np.int32)
    masks[masked_ids] = np.arange(len(masked_ids))
    extra = np.array(additional_masks, dtype=np.int32)
    extra[extra >= 0] += len(masked_ids)
    masks[len(unchanged):] = extra
    uvs = np.concatenate([source.arrays['maskedUvs'][original_masks[masked_ids]], np.array(added_uvs).reshape(-1, 3, 2)])
    materials = np.r_[source.arrays['maskedMaterials'][original_masks[masked_ids]], added_materials]
    correspondence = eligible[np.r_[unchanged, added_source]]
    proof = dict(originalObserverHeightDomainMeters=observer_domain, groundReferenceHeightDomainMeters=field_domain,
                 maximumInverseCoordinateErrorMeters=maximum_inverse_error, maximumAreaPartitionErrorMeters2=float(errors.max(initial=0)),
                 omittedDegenerateOrOutsideSourceFaces=eligible[missing].tolist(), sourceFaces=len(all_faces),
                 sourceHeightCullDomainMeters=source_domain, outsideFieldClippedFaces=len(outside_faces),
                 coplanarFacesNotSplit=fast_path_faces, maximumCoplanarTransformErrorMeters=maximum_fast_path_error,
                 heightOrXYExcludedFaces=len(all_faces) - len(eligible), retainedSourceFaces=int(covered.sum()))
    report = write_pack(source, pack, output, points, faces, masks, uvs, materials, correspondence, hashlib.sha256(field.bytes).hexdigest(), relative_domain, proof)
    report.update(sourceFaces=len(original_faces), crossingFaces=len(crossing), sourceCoverage=int(covered.sum()),
                  maximumInverseErrorMeters=maximum_inverse_error, seconds=time.perf_counter() - started,
                  coordinatePolicy='tactical-floor-relative-v1', status='candidate-gameplay-not-yet-certified')
    (output / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
    (output / (source.header['map'] + '.tactical-ground.json.gz')).write_bytes(field.bytes)
    print(json.dumps(report), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pack', type=Path)
    parser.add_argument('field', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    build(args.pack, args.field, args.output)
