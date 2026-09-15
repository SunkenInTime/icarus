"""Bounded proof of opaque 2D sections on already selected affine floor patches.

This does not select floors, bridge gaps, simplify masks, or install map data.
Each tested ray stays inside one convex floor footprint, including its recorded
seam extension. The reference intersects
the original 3D triangles; the candidate intersects precomputed 2D segments.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import numpy as np
import shapely

from audit_tactical_target_rays import ReferenceModel
from static_alpha_sections import opaque_intervals


def cross(a, b):
    return a[..., 0] * b[..., 1] - a[..., 1] * b[..., 0]


def query_box(source, lower, upper):
    bounds, nodes = source.arrays['bounds'], source.arrays['nodes']
    pending, faces = [0], []
    while pending:
        index = pending.pop()
        box = bounds[index]
        if any(box[axis] > upper[axis] or box[axis + 3] < lower[axis]
               for axis in range(3)):
            continue
        start, count, left, right = nodes[index]
        if count:
            faces.extend(range(int(start), int(start + count)))
        else:
            pending.extend((int(left), int(right)))
    return np.array(faces, dtype=np.int64)


def sections(points, ids, plane, patch):
    """Clip source/eye-plane intersections to a convex patch, including points.

    A repeated endpoint represents an isolated contact. Source face IDs remain
    necessary to resolve ray directions coplanar with the original triangle.
    """
    distance = points[:, :, 2] - points[:, :, :2] @ plane[:2] - plane[2] - 1.75
    coplanar = np.all(abs(distance) < 1e-10, axis=1)
    if coplanar.any():
        return None
    endpoints = []
    face_ids = []
    for triangle, values, face in zip(points, distance, ids):
        # Classifying zero as the negative side drops a top edge (two zeros,
        # one negative vertex), as well as a lone tangent vertex. Retain zeros
        # explicitly and only interpolate edges with strictly opposite signs.
        cuts = [triangle[index, :2] for index in np.flatnonzero(values == 0)]
        for edge in range(3):
            following = (edge + 1) % 3
            if not ((values[edge] < 0 < values[following]) or
                    (values[following] < 0 < values[edge])):
                continue
            t = -values[edge] / (values[following] - values[edge])
            cuts.append(triangle[edge, :2] + t * (triangle[following, :2] - triangle[edge, :2]))
        if not cuts:
            continue
        a, b = cuts[0], cuts[-1]
        lo, hi = 0., 1.
        sign = np.sign(sum(cross(patch[i], patch[(i + 1) % len(patch)]) for i in range(len(patch))))
        for edge in range(len(patch)):
            p, q = patch[edge], patch[(edge + 1) % len(patch)]
            start = sign * cross(q - p, a - p)
            slope = sign * cross(q - p, b - a)
            if abs(slope) < 1e-14:
                if start < -1e-10:
                    hi = -1.
                    break
            elif slope > 0:
                lo = max(lo, -start / slope)
            else:
                hi = min(hi, -start / slope)
        # A clipping corner can reduce a nonzero source edge to a point. Tiny
        # positive sections must not be discarded by a minimum-length gate.
        if hi >= lo:
            endpoints.append([a + lo * (b - a), a + hi * (b - a)])
            face_ids.append(int(face))
    return np.array(endpoints, dtype=float).reshape(-1, 2, 2), face_ids


def cast_segments(start, end, segments):
    """Diagnostic transverse casting; point contacts conservatively block.

    A point's source face is needed to exclude triangle-coplanar directions in
    an exact source-policy consumer. This helper does not perform that check.
    """
    d = end - start
    a = segments[:, 0] - start
    e = segments[:, 1] - segments[:, 0]
    determinant = cross(d, e)
    valid = determinant != 0
    t = np.full(len(segments), np.inf)
    u = np.full(len(segments), np.inf)
    t[valid] = cross(a[valid], e[valid]) / determinant[valid]
    u[valid] = cross(a[valid], d) / determinant[valid]
    points = np.all(e == 0, axis=1)
    if np.any(points) and np.dot(d, d) > 0:
        point_t = a[points] @ d / np.dot(d, d)
        on_ray = abs(cross(a[points], d)) <= 1e-12 * max(1., np.linalg.norm(d))
        point_ids = np.flatnonzero(points)[on_ray]
        t[point_ids] = point_t[on_ray]
        u[point_ids] = 0.
        valid[point_ids] = True
    valid &= (t > 1e-7) & (t < 1 - 1e-7) & (u >= -1e-9) & (u <= 1 + 1e-9)
    return None if not valid.any() else float(t[valid].min())


def apply_alpha_sections(source, points, result, plane):
    segments, face_ids = result
    output, owners = [], []
    for segment, face in zip(segments, face_ids):
        mask = source.arrays['faceMasks'][face]
        if mask < 0:
            output.append(segment); owners.append(face)
            continue
        xyz = np.c_[segment, segment @ plane[:2] + plane[2] + 1.75]
        barycentric = np.linalg.lstsq(np.vstack([points[face].T, np.ones(3)]),
                                     np.c_[xyz, np.ones(2)].T, rcond=None)[0].T
        uvs = barycentric @ source.arrays['maskedUvs'][mask]
        material = source.materials[int(source.arrays['maskedMaterials'][mask])]
        intervals = opaque_intervals(source.textures[material['texture']], *uvs, material)
        pieces = segment[0] + intervals[:, :, None] * (segment[1] - segment[0])
        output.extend(pieces); owners.extend([face] * len(pieces))
    return np.array(output).reshape(-1, 2, 2), owners


def run(revision, name, count, rays, include_masked=False):
    source_path = revision / 'full-height-input-v1' / name / f'{name}.height.bin.gz'
    support_path = revision / 'source-floor-support-union-v6' / f'{name}.floor-support.npz'
    source = ReferenceModel(source_path)
    support = np.load(support_path)
    points = source.arrays['vertices'][source.arrays['faces']]
    lower, upper = points[:, :, :2].min(1), points[:, :, :2].max(1)
    floors = support['vertices'][support['triangles']]
    areas = abs(cross(floors[:, 1, :2] - floors[:, 0, :2], floors[:, 2, :2] - floors[:, 0, :2])) / 2
    eligible = np.flatnonzero((support['sourceFaces'] >= 0) & (areas > .5))
    rng = np.random.default_rng(849217)
    rng.shuffle(eligible)
    reports, all_segments, all_faces = [], [], []
    masked_rays = coplanar_patches = verified_masked_hits = 0
    errors = []
    mismatches = []
    for floor_id in eligible:
        patch = floors[floor_id]
        plane = np.linalg.solve(np.c_[patch[:, :2], np.ones(3)], patch[:, 2])
        extension = float(support['extensionMeters'][floor_id])
        footprint = shapely.Polygon(patch[:, :2])
        if extension:
            footprint = shapely.buffer(footprint, extension)
        polygon = np.array(footprint.exterior.coords)[:-1]
        lo, hi = polygon.min(0), polygon.max(0)
        heights = polygon @ plane[:2] + plane[2] + 1.75
        candidate = query_box(source, np.r_[lo, heights.min()] - 1e-8,
                             np.r_[hi, heights.max()] + 1e-8)
        opaque = candidate if include_masked else candidate[source.arrays['faceMasks'][candidate] < 0]
        result = sections(points[opaque], opaque, plane, polygon)
        if result is None:
            coplanar_patches += 1
            continue
        segments, face_ids = apply_alpha_sections(source, points, result, plane) if include_masked else result
        if not len(segments):
            continue
        # Independent broad XY scan certifies the BVH acceleration did not
        # discard a blocker section. Sorting removes traversal-order effects.
        reference_ids = np.flatnonzero(np.all(upper >= lo, axis=1) & np.all(lower <= hi, axis=1))
        if not include_masked:
            reference_ids = reference_ids[source.arrays['faceMasks'][reference_ids] < 0]
        reference = sections(points[reference_ids], reference_ids, plane, polygon)
        if reference is None:
            raise AssertionError('BVH omitted a coplanar face')
        expected_segments, expected_ids = apply_alpha_sections(source, points, reference, plane) if include_masked else reference
        actual_order, expected_order = np.argsort(face_ids, kind='stable'), np.argsort(expected_ids, kind='stable')
        np.testing.assert_array_equal(np.array(face_ids)[actual_order], np.array(expected_ids)[expected_order])
        np.testing.assert_allclose(segments[actual_order], expected_segments[expected_order], atol=1e-12, rtol=0)
        all_segments.extend(segments)
        all_faces.extend(face_ids)
        hits = misses = 0
        for ray in range(rays):
            weights = rng.dirichlet([1, 1, 1], size=2)
            if ray % 2:
                xy = []
                for weight in weights:
                    edge = int(rng.integers(len(polygon)))
                    triangle = np.array([polygon[edge], polygon[(edge + 1) % len(polygon)], patch[:, :2].mean(0)])
                    xy.append(weight @ triangle)
                xy = np.array(xy)
            else:
                xy = weights @ patch[:, :2]
            endpoints = np.c_[xy, xy @ plane[:2] + plane[2] + 1.75]
            hit = source.cast(*endpoints)
            if hit is not None and hit['masked'] and not include_masked:
                masked_rays += 1
                continue
            verified_masked_hits += hit is not None and hit['masked']
            expected = None if hit is None else hit['distanceMeters'] / np.linalg.norm(endpoints[1] - endpoints[0])
            actual = cast_segments(*endpoints[:, :2], segments)
            if (actual is None) != (expected is None):
                mismatches.append(dict(floor=int(floor_id), origin=endpoints[0].tolist(), target=endpoints[1].tolist(), actual=actual, expected=expected))
            elif actual is not None:
                error = abs(actual - expected) * np.linalg.norm(endpoints[1, :2] - endpoints[0, :2])
                errors.append(error)
                if error > 1e-6:
                    mismatches.append(dict(floor=int(floor_id), errorMeters=error))
            hits += expected is not None
            misses += expected is None
        reports.append(dict(floor=int(floor_id), areaMetersSquared=float(footprint.area), extensionMeters=extension, candidates=len(candidate), segments=len(segments), hits=hits, clear=misses))
        print(name, 'patch', len(reports), 'sections', len(segments), 'verified hits/clear', hits, misses, flush=True)
        if len(reports) >= count:
            break
    output = revision / ('static-floor-sections-masked-v4' if include_masked else 'static-floor-sections-probe-v3')
    output.mkdir(exist_ok=True)
    payload = io.BytesIO()
    np.savez_compressed(payload, segments=np.array(all_segments), sourceFaces=np.array(all_faces, dtype=np.uint32))
    (output / f'{name}.sections.npz').write_bytes(payload.getvalue())
    report = dict(scope=__doc__, map=name,
        sourceSha256=hashlib.sha256(source_path.read_bytes()).hexdigest(),
        supportSha256=hashlib.sha256(support_path.read_bytes()).hexdigest(),
        eligibleFloorPatches=len(eligible), testedPatches=len(reports), patches=reports,
        sourceFaces=len(points), sectionSegments=len(all_segments),
        compressedSectionBytes=len(payload.getvalue()),
        unsupportedCoplanarPatches=coplanar_patches, skippedMaskedReferenceRays=masked_rays,
        includesPrecomputedAlphaIntervals=include_masked,
        verifiedMaskedHits=int(verified_masked_hits),
        verifiedHits=len(errors), maximumDistanceErrorMeters=max(errors, default=0.),
        mismatches=mismatches,
        limitation='Sections are clipped to isolated floor patches. Branch selection, gaps, raised observers and coplanar blockers need separate representation. Alpha intervals use frozen material policy, not animated shaders. No whole-map compression claim.')
    (output / f'{name}.json').write_text(json.dumps(report, indent=2) + '\n')
    if mismatches:
        raise AssertionError(f'{len(mismatches)} section mismatches')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--revision', type=Path, required=True)
    parser.add_argument('--map', default='icebox')
    parser.add_argument('--patches', type=int, default=32)
    parser.add_argument('--rays', type=int, default=64)
    parser.add_argument('--include-masked', action='store_true')
    args = parser.parse_args()
    run(args.revision, args.map, args.patches, args.rays, args.include_masked)
