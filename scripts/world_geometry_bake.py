"""Bake compact, planarized standing visibility layers from placed triangles.

Expensive mesh intersection, texture cutouts, overlap removal and edge indexing
run offline. Runtime assets contain UV vectors and shared edge IDs only.
"""
import argparse
from collections import Counter
import gzip
import hashlib
import json
from pathlib import Path
import time

import numpy as np
import shapely


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def intersect_triangles(triangles, elevation, triangle_uvs=None):
    """Return section endpoints and source triangle IDs, without triangle inflation."""
    dz = triangles[:, :, 2] - elevation
    selected = np.flatnonzero((dz.min(axis=1) <= 0) & (dz.max(axis=1) >= 0))
    if not len(selected):
        return np.empty((0, 2, 2)), np.empty(0, dtype=np.int32), None
    tri, z = triangles[selected], dz[selected]
    corners = np.array([1, 2, 0])
    crosses = (z <= 0) != (z[:, corners] <= 0)
    regular = crosses.sum(axis=1) == 2
    ids = selected[regular]
    tri, z, crosses = tri[regular], z[regular], crosses[regular]
    face_rows, edge_starts = np.nonzero(crosses)
    edge_ends = corners[edge_starts]
    t = -z[face_rows, edge_starts] / (z[face_rows, edge_ends] - z[face_rows, edge_starts])
    a, b = tri[face_rows, edge_starts], tri[face_rows, edge_ends]
    segments = (a + (b - a) * t[:, None])[:, :2].reshape(-1, 2, 2)
    texture = None
    if triangle_uvs is not None:
        uv = triangle_uvs[ids]
        a, b = uv[face_rows, edge_starts], uv[face_rows, edge_ends]
        texture = (a + (b - a) * t[:, None]).reshape(-1, 2, 2)
    nonzero = np.linalg.norm(segments[:, 1] - segments[:, 0], axis=1) > 1e-9
    segments, ids = segments[nonzero], ids[nonzero]
    texture = texture[nonzero] if texture is not None else None
    # A plane exactly on a triangle's top edge has no sign transition under
    # the half-open rule above, but that edge remains a real horizontal blocker.
    special = selected[(dz[selected] == 0).sum(axis=1) == 2]
    special = special[(dz[special] <= 0).all(axis=1)]
    if len(special):
        rows, columns = np.nonzero(dz[special] == 0)
        extra = triangles[special][rows, columns, :2].reshape(-1, 2, 2)
        valid = np.linalg.norm(extra[:, 1] - extra[:, 0], axis=1) > 1e-9
        segments = np.concatenate([segments, extra[valid]])
        ids = np.concatenate([ids, special[valid]])
        if texture is not None:
            extra_uv = triangle_uvs[special][rows, columns].reshape(-1, 2, 2)
            texture = np.concatenate([texture, extra_uv[valid]])
    return segments, ids, texture


def project_segments(segments, ui, scale):
    if not len(segments):
        return np.empty((0, 2, 2))
    points = segments.copy()
    x, y = points[:, :, 0].copy(), points[:, :, 1].copy()
    points[:, :, 0] = -y * 100 * ui['XMultiplier'] + ui['XScalarToAdd']
    points[:, :, 1] = x * 100 * ui['YMultiplier'] + ui['YScalarToAdd']
    return points * scale


def planarize_segments(segments, ui, scale):
    """Split crossings and remove overlaps on the final fixed precision UV grid."""
    points = np.rint(project_segments(segments, ui, scale)).astype(np.int64)
    valid = np.any(points[:, 0] != points[:, 1], axis=1)
    if not valid.any():
        return []
    # Grid=1 is the output coordinate unit, typically about 0.12 mm in world XY.
    # Union inserts crossing vertices, needed by the runtime's endpoint events.
    lines = shapely.linestrings(points[valid])
    union = shapely.union_all(lines, grid_size=1)
    merged = shapely.line_merge(union)
    result = []
    for line in shapely.get_parts(merged):
        if line.geom_type != 'LineString':
            continue
        coords = np.rint(shapely.get_coordinates(line)).astype(np.int64)
        # Remove only exactly collinear internal points; preserve every corner.
        stack = []
        for point in coords:
            p = (int(point[0]), int(point[1]))
            if stack and p == stack[-1]:
                continue
            while len(stack) >= 2:
                a, b = stack[-2], stack[-1]
                cross = (b[0] - a[0]) * (p[1] - b[1]) - (b[1] - a[1]) * (p[0] - b[0])
                dot = (b[0] - a[0]) * (p[0] - b[0]) + (b[1] - a[1]) * (p[1] - b[1])
                if cross != 0 or dot < 0:
                    break
                stack.pop()
            stack.append(p)
        result.extend((min(a, b), max(a, b)) for a, b in zip(stack, stack[1:]) if a != b)
    return sorted(set(result))


def standing_elevations(navigation, refinement, floor_mesh, eye_height_cm, step_cm):
    """Bound height spacing and add exact, frequently occupied flat floors."""
    if not np.isfinite(step_cm) or step_cm <= 0:
        raise ValueError('Layer spacing must be finite and positive.')
    heights = np.asarray(refinement['refinedFloorHeightsCm'])
    vertices = np.asarray(floor_mesh['vertices']).reshape(-1, 3)
    faces = np.asarray(floor_mesh['triangles']).reshape(-1, 4)[:, 1:]
    z = vertices[faces, 2]
    minimum = min(heights.min(), z.min()) + eye_height_cm
    maximum = max(heights.max(), z.max()) + eye_height_cm
    values = set(np.arange(np.floor(minimum / step_cm) * step_cm,
                           np.ceil(maximum / step_cm) * step_cm + step_cm / 2, step_cm))
    uv = vertices[faces, :2]
    a, b = uv[:, 1] - uv[:, 0], uv[:, 2] - uv[:, 0]
    areas = np.abs(a[:, 0] * b[:, 1] - a[:, 1] * b[:, 0]) / 2
    flat = np.ptp(z, axis=1) <= .02
    # Flat-floor bins below 0.1 mm remain below the source/output precision;
    # broad floors get an exact plane rather than a nearby regular slice.
    grouped = Counter()
    for level, area in zip(np.round(z[flat].mean(axis=1), 2), areas[flat]):
        grouped[float(level)] += float(area)
    total = areas.sum()
    for level, area in grouped.items():
        if area >= total * .001:
            values.add(level + eye_height_cm)
    return sorted(round(float(value), 6) for value in values)


def floor_ranges_by_polygon(navigation, refinement, floor_mesh):
    """Conservative heights for every parent polygon used by runtime floor lookup."""
    count = len(navigation['polygons'])
    minimum, maximum = np.full(count, np.inf), np.full(count, -np.inf)
    fallback = np.asarray(refinement['refinedFloorHeightsCm'])
    detail = np.asarray(navigation['triangles']).reshape(-1, 4)
    np.minimum.at(minimum, detail[:, 0], fallback[detail[:, 1:]].min(axis=1))
    np.maximum.at(maximum, detail[:, 0], fallback[detail[:, 1:]].max(axis=1))
    vertices = np.asarray(floor_mesh['vertices']).reshape(-1, 3)
    detail = np.asarray(floor_mesh['triangles']).reshape(-1, 4)
    np.minimum.at(minimum, detail[:, 0], vertices[detail[:, 1:], 2].min(axis=1))
    np.maximum.at(maximum, detail[:, 0], vertices[detail[:, 1:], 2].max(axis=1))
    return minimum, maximum


def bake(folder, navigation_path, output_path, eye_height_cm=175, layer_step_cm=1,
         only_elevations=None, max_layers=None, texture_properties_root=None, cache_folder=None,
         max_distance_meters=None, cache_only=False):
    from world_visibility_materials import build_policy, clip_alpha_segment, AlphaSamplingError
    from world_visibility_reduce import navigation_domain, visible_region, visible_segment_indices, reduce_segments

    folder, output_path = Path(folder), Path(output_path)
    metadata = json.loads((folder / 'geometry.json').read_text(encoding='utf-8'))
    if metadata['geometrySha256'] != digest(folder / 'geometry.npz'):
        raise ValueError('Placed geometry fingerprint does not match.')
    nav_bytes = Path(navigation_path).read_bytes()
    navigation = json.loads(nav_bytes)
    refinement = json.loads((folder / 'floor-refinement.json').read_text(encoding='utf-8'))
    if refinement['navigationSha256'] != hashlib.sha256(nav_bytes).hexdigest():
        raise ValueError('Floor refinement and navigation have different fingerprints.')
    floor_data = json.loads((folder / 'floor-mesh.json').read_text(encoding='utf-8'))
    if (floor_data['navigationSha256'] != digest(navigation_path) or
            floor_data['geometrySha256'] != metadata['geometrySha256']):
        raise ValueError('Detailed floor and world geometry have different fingerprints.')
    source = np.load(folder / 'geometry.npz')
    triangles = source['points'][source['faces']]
    uvs, material_ids = source['uvs'], source['material_indices']
    policies = [build_policy(m, texture_properties_root=texture_properties_root) for m in metadata['materials']]
    include = np.array([p['mode'] != 'ignore' for p in policies])[material_ids]
    triangles, uvs, material_ids = triangles[include], uvs[include], material_ids[include]
    heights = np.asarray(refinement['refinedFloorHeightsCm'])
    elevations = standing_elevations(navigation, refinement, floor_data['floorMesh'], eye_height_cm, layer_step_cm)
    if only_elevations:
        elevations = sorted(set(only_elevations))
    if max_layers:
        elevations = elevations[:max_layers]
    # Publish only common ground levels as UI choices; fine slices stay internal.
    common = Counter(int(round(z)) for z in heights)
    menu = sorted(z + eye_height_cm for z, count in common.items() if count >= max(8, len(heights) * 0.02))
    default_floor = common.most_common(1)[0][0]
    menu = menu or [default_floor + eye_height_cm]
    if not only_elevations:
        elevations = sorted(set(elevations) | set(menu))
    global_elevations = {min(elevations, key=lambda value: abs(value - target)) for target in menu}
    # Explicit one-plane probes remain global so they can test arbitrary
    # navigation origins against a full 3D reference at that requested height.
    if only_elevations and len(elevations) == 1:
        global_elevations = set(elevations)
    scale = 1048576
    all_observer_domain = navigation_domain(navigation, scale)
    polygon_min, polygon_max = floor_ranges_by_polygon(navigation, refinement, floor_data['floorMesh'])
    nav_walkable = np.asarray(navigation.get('walkable', [True] * len(navigation['polygons'])))
    nav_xy = np.asarray(navigation['vertices']).reshape(-1, 3)[:, :2] * (scale / navigation['coordinateScale'])
    nav_polygons = np.array([shapely.Polygon(nav_xy[p]) for p in navigation['polygons']], dtype=object)
    range_domain = None
    if max_distance_meters is not None:
        if not np.isfinite(max_distance_meters) or max_distance_meters <= 0:
            raise ValueError('Maximum distance must be finite and positive.')
        # Buffer in physical meters, not artwork pixels. A circumscribed
        # polygon keeps the boundary conservative between buffer vertices.
        from shapely import affinity
        unit_u = abs(metadata['uiTransform']['XMultiplier']) * 100 * scale
        unit_v = abs(metadata['uiTransform']['YMultiplier']) * 100 * scale
        metric_domain = affinity.scale(all_observer_domain, 1 / unit_u, 1 / unit_v, origin=(0, 0))
        radius = max_distance_meters / np.cos(np.pi / 128)
        range_domain = affinity.scale(metric_domain.buffer(radius, quad_segs=32), unit_u, unit_v, origin=(0, 0))
        shapely.prepare(range_domain)
    cache_folder = Path(cache_folder) if cache_folder else folder / 'visibility-cache'
    cache_folder.mkdir(parents=True, exist_ok=True)
    cache_fingerprint = hashlib.sha256(json.dumps({
        'geometry': metadata['geometrySha256'], 'navigation': digest(navigation_path),
        'policies': policies, 'scale': scale, 'ui': metadata['uiTransform'],
        'baker': digest(__file__), 'materials': digest(Path(__file__).with_name('world_visibility_materials.py')),
        'reduction': digest(Path(__file__).with_name('world_visibility_reduce.py')),
        'maxDistanceMeters': max_distance_meters, 'floorMesh': digest(folder / 'floor-mesh.json'),
    }, sort_keys=True).encode()).hexdigest()
    vertices, edges, layers = [], [], []
    vertex_ids, edge_ids = {}, {}
    statistics = []
    alpha_failures = Counter()
    output_path.parent.mkdir(parents=True, exist_ok=True)
    started = time.perf_counter()
    for count, elevation in enumerate(elevations):
        tick = time.perf_counter()
        global_origins = elevation in global_elevations
        if global_origins:
            observer_domain = all_observer_domain
        else:
            lower = (elevations[count - 1] + elevation) / 2 - eye_height_cm if count else -np.inf
            upper = (elevations[count + 1] + elevation) / 2 - eye_height_cm if count + 1 < len(elevations) else np.inf
            allowed = nav_walkable & (polygon_min <= upper + .001) & (polygon_max >= lower - .001)
            if not allowed.any():
                continue
            observer_domain = shapely.union_all(nav_polygons[allowed])
        domain_hash = hashlib.sha256(observer_domain.wkb).hexdigest()[:12]
        cache_path = cache_folder / (f'{elevation:.6f}-{cache_fingerprint[:16]}-{domain_hash}.json.gz')
        if cache_path.exists():
            cached = json.loads(gzip.decompress(cache_path.read_bytes()))
            planar = [(tuple(a), tuple(b)) for a, b in cached['segments']]
            stats = cached['statistics']
            alpha_failures.update(cached['alphaFailures'])
        else:
            segments, face_ids, texture_segments = intersect_triangles(triangles, elevation / 100, uvs)
            original_count = len(segments)
            if range_domain is not None and len(segments):
                in_range = shapely.intersects(range_domain, shapely.linestrings(project_segments(segments, metadata['uiTransform'], scale)))
                segments, face_ids, texture_segments = segments[in_range], face_ids[in_range], texture_segments[in_range]
            selected_materials = material_ids[face_ids]
            solid = np.array([policies[int(i)]['mode'] != 'alpha-test' for i in selected_materials], dtype=bool)
            solid_planar = planarize_segments(segments[solid], metadata['uiTransform'], scale)
            projected = project_segments(segments, metadata['uiTransform'], scale)
            bounds = [*projected.min(axis=(0, 1)), *projected.max(axis=(0, 1))] if len(projected) else None
            region, pre_stats = visible_region(solid_planar, observer_domain, candidate_bounds=bounds)
            solid_keep = visible_segment_indices(solid_planar, region)
            # Alpha is absent from this first arrangement: it can overestimate
            # visibility but cannot hide a real cutout or first blocking edge.
            alpha_indices = np.flatnonzero(~solid)
            if len(alpha_indices):
                alpha_indices = alpha_indices[shapely.intersects(region, shapely.linestrings(projected[alpha_indices]))]
            parts = []
            alpha_count = 0
            failures = Counter()
            for index in alpha_indices:
                policy = policies[int(selected_materials[index])]
                try:
                    intervals = clip_alpha_segment(policy, texture_segments[index, 0], texture_segments[index, 1])
                except AlphaSamplingError as error:
                    failures[str(error)] += 1
                    intervals = [(0, 1)]
                a, b = segments[index]
                for start, end in intervals:
                    if end > start:
                        parts.append(np.array([[a + (b - a) * start, a + (b - a) * end]]))
                        alpha_count += 1
            # Return retained solid edges to world XY before the final union;
            # their integer-grid coordinates round-trip exactly.
            kept_solid = np.asarray(solid_planar)[solid_keep] if len(solid_keep) else np.empty((0, 2, 2))
            ui = metadata['uiTransform']
            world_solid = np.empty_like(kept_solid, dtype=float)
            world_solid[:, :, 0] = (kept_solid[:, :, 1] / scale - ui['YScalarToAdd']) / (100 * ui['YMultiplier'])
            world_solid[:, :, 1] = -(kept_solid[:, :, 0] / scale - ui['XScalarToAdd']) / (100 * ui['XMultiplier'])
            clipped = np.concatenate([world_solid, *parts]) if parts else world_solid
            planar = planarize_segments(clipped, metadata['uiTransform'], scale)
            planar, reduction = reduce_segments(planar, observer_domain)
            stats = {'elevationCm': float(elevation), 'rawSegments': original_count,
                     'inRangeSegments': len(segments),
                     'alphaCandidates': int((~solid).sum()), 'visibleAlphaCandidates': len(alpha_indices),
                     'alphaSegments': alpha_count, 'segments': len(planar),
                     'preReduction': pre_stats, 'reduction': reduction,
                     'seconds': time.perf_counter() - tick}
            cache_path.write_bytes(gzip.compress(json.dumps({'segments': planar, 'statistics': stats,
                'alphaFailures': dict(failures)}, separators=(',', ':')).encode(), compresslevel=3, mtime=0))
            alpha_failures.update(failures)
        layer_ids = []
        for a, b in ([] if cache_only else planar):
            key = a, b
            if key not in edge_ids:
                endpoint_ids = []
                for point in key:
                    if point not in vertex_ids:
                        vertex_ids[point] = len(vertices) // 2
                        vertices.extend(point)
                    endpoint_ids.append(vertex_ids[point])
                edge_ids[key] = len(edges) // 2
                edges.extend(endpoint_ids)
            layer_ids.append(edge_ids[key])
        layer_record = {'elevationCm': elevation, 'globalOrigins': global_origins}
        if cache_only:
            layer_record['cacheFile'] = str(cache_path.resolve())
        else:
            layer_record['edges'] = layer_ids
        layers.append(layer_record)
        statistics.append(stats)
        if count % 20 == 0 or count == len(elevations) - 1:
            print(json.dumps({'map': metadata['map'], 'layer': count + 1, 'of': len(elevations),
                              'segments': len(planar), 'uniqueEdges': len(edge_ids),
                              'seconds': time.perf_counter() - started}), flush=True)
    result = {'version': 1, 'map': metadata['map'], 'coordinateScale': scale, 'planarized': True,
              'uvUnitsPerMeter': [abs(metadata['uiTransform']['XMultiplier']) * 100,
                                 abs(metadata['uiTransform']['YMultiplier']) * 100],
              'observerHeightCm': eye_height_cm, 'defaultFloorElevationCm': default_floor,
              'menuElevationsCm': [value for value in elevations if value in global_elevations],
              'vertices': vertices, 'edges': edges, 'layers': layers,
              'source': {'referenceSha256': metadata['referenceSha256'],
                         'geometrySha256': metadata['geometrySha256'],
                         'navigationSha256': hashlib.sha256(nav_bytes).hexdigest(),
                         'layerStepCm': layer_step_cm, 'dynamicState': 'excluded',
                         'eyeHeightEvidence': 'BasePawn capsule98cm plus BaseEyeHeight77cm; standing nominal.'}}
    if max_distance_meters is not None:
        result['maxDistanceMeters'] = max_distance_meters
    if cache_only:
        result.pop('vertices')
        result.pop('edges')
        result['format'] = 'plane-cache-v1'
    raw = json.dumps(result, separators=(',', ':')).encode('utf-8')
    output_path.write_bytes(raw if cache_only else gzip.compress(raw, compresslevel=9, mtime=0))
    navigation['refinedFloorHeightsCm'] = refinement['refinedFloorHeightsCm']
    navigation['floorMesh'] = floor_data['floorMesh']
    navigation['observerHeightCm'] = eye_height_cm
    navigation['defaultFloorElevationCm'] = default_floor
    nav_output = output_path.with_name(metadata['map'] + '_navigation.json.gz')
    nav_output.write_bytes(gzip.compress(json.dumps(navigation, separators=(',', ':')).encode('utf-8'), compresslevel=9, mtime=0))
    audit = {'map': metadata['map'], 'status': 'offline-standing-world-bake',
             'gameplayCertified': False, 'referenceSha256': metadata['referenceSha256'],
             'policies': policies, 'layers': statistics,
             'alphaSamplingFailures': dict(alpha_failures),
             'summary': {'layers': len(layers), 'uniqueVertices': len(vertices) // 2,
                         'uniqueEdges': len(edges) // 2, 'uncompressedBytes': len(raw),
                         'compressedBytes': output_path.stat().st_size,
                         'maximumSegments': max(l['segments'] for l in statistics),
                         'seconds': time.perf_counter() - started}}
    output_path.with_suffix('.audit.json').write_text(json.dumps(audit, indent=2), encoding='utf-8')
    print(json.dumps(audit['summary']), flush=True)
    return audit


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder')
    parser.add_argument('navigation')
    parser.add_argument('output')
    parser.add_argument('--eye-height-cm', type=float, default=175)
    parser.add_argument('--layer-step-cm', type=float, default=1)
    parser.add_argument('--elevations', type=float, nargs='+')
    parser.add_argument('--max-layers', type=int)
    parser.add_argument('--texture-properties-root')
    parser.add_argument('--cache-folder')
    parser.add_argument('--max-distance-meters', type=float)
    parser.add_argument('--elevations-file', help='JSON array of explicit observer elevations in centimeters.')
    parser.add_argument('--cache-only', action='store_true', help='Write a small plane manifest for bounded-memory chunk assembly.')
    args = parser.parse_args()
    elevations = json.loads(Path(args.elevations_file).read_text()) if args.elevations_file else args.elevations
    bake(args.folder, args.navigation, args.output, args.eye_height_cm,
         args.layer_step_cm, elevations, args.max_layers, args.texture_properties_root, args.cache_folder,
         args.max_distance_meters, args.cache_only)
