"""Bake a continuous tactical ground reference from the main navigation sheet.

Disconnected navigation components do not become ground anchors: boxes retain
their height above the surrounding sheet. This is a declared 2D ramp policy,
not equivalence to straight sight rays over a 3D hill.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import numpy as np
import shapely


def lower_arrangement(vertices, triangles, variant='lower'):
    """Node projected sheets, then share the lowest source height at each node.

    Upper source geometry is not changed here. Only its reference height is
    defined, keeping vertical separation in the later geometry transform.
    """
    source_points = vertices[triangles]
    source_polygons = shapely.polygons(source_points[:, :, :2])
    source_tree = shapely.STRtree(source_polygons)
    source_planes = np.linalg.solve(np.concatenate([source_points[:, :, :2], np.ones((len(triangles), 3, 1))], 2),
                                    source_points[:, :, 2, None])[:, :, 0]
    linework = shapely.union_all(shapely.boundary(source_polygons))
    cells = shapely.get_parts(shapely.polygonize(shapely.get_parts(linework)))
    union = shapely.union_all(source_polygons)
    cells = cells[shapely.covers(union, shapely.point_on_surface(cells))]
    pieces = []
    for cell in cells:
        pieces.extend(shapely.get_parts(shapely.constrained_delaunay_triangles(cell)))
    points, faces, lookup = [], [], {}
    def lower_height(xy):
        candidates = source_tree.query(shapely.Point(xy).buffer(1e-8), predicate='intersects')
        if not len(candidates):
            raise ValueError('Arrangement vertex outside original ground')
        values = source_planes[candidates, :2] @ xy + source_planes[candidates, 2]
        return float(np.min(values) if variant == 'lower' else np.max(values))
    for piece in pieces:
        face = []
        for xy in np.array(piece.exterior.coords)[:3]:
            key = tuple(xy)
            if key not in lookup:
                lookup[key] = len(points)
                points.append([*xy, lower_height(xy)])
            face.append(lookup[key])
        faces.append(face)
    points, faces = np.array(points), np.array(faces)
    centroids = points[faces].mean(1)
    deviations = np.array([p[2] - lower_height(p[:2]) for p in centroids])
    report = dict(policy=f'continuous-{variant}-envelope-at-arrangement-vertices',
                  sourceTriangles=len(triangles), arrangementTriangles=len(faces),
                  maximumCentroidDeviationMeters=float(np.abs(deviations).max(initial=0)),
                  p95CentroidDeviationMeters=float(np.percentile(np.abs(deviations), 95)),
                  cellsOver10cmDeviation=int(np.sum(np.abs(deviations) > .1)),
                  mostChanged=[dict(xyz=centroids[i].tolist(), deviationMeters=float(deviations[i]))
                               for i in np.argsort(np.abs(deviations))[-20:][::-1]])
    return points, faces, report


def build(nav_path, catalog_path, map_name, output, variant='lower'):
    nav_bytes = nav_path.read_bytes()
    nav = json.loads(gzip.decompress(nav_bytes))
    ui = json.loads(catalog_path.read_text())['maps'][map_name]['uiTransform']
    vertices = np.array(nav['vertices'], dtype=float).reshape(-1, 3)
    uv = vertices[:, :2] / nav['coordinateScale']
    vertices[:, 0] = (uv[:, 1] - ui['YScalarToAdd']) / (100 * ui['YMultiplier'])
    vertices[:, 1] = -(uv[:, 0] - ui['XScalarToAdd']) / (100 * ui['XMultiplier'])
    vertices[:, 2] = np.array(nav['refinedFloorHeightsCm']) / 100
    source = np.array(nav['triangles']).reshape(-1, 4)
    ids = np.flatnonzero(nav['walkable'])
    component_areas = {}
    for i in ids:
        component = nav['components'][i]
        area = shapely.Polygon(vertices[nav['polygons'][i], :2]).area
        component_areas[component] = component_areas.get(component, 0) + area
    main = max(component_areas, key=component_areas.get)
    # Alternate charts describe connected floor branches, not every reachable
    # box top. Disconnected props retain their real elevation above either
    # ground reference rather than becoming an elevated chart anchor.
    included = {main}
    main_polygons = [shapely.Polygon(vertices[nav['polygons'][i], :2]) for i in ids if nav['components'][i] in included]
    stacked = sum(shapely.area(main_polygons)) - shapely.union_all(main_polygons).area > 1e-5
    main_ids = np.unique(np.concatenate([nav['polygons'][i] for i in ids if nav['components'][i] in included]))
    lookup = {tuple(vertices[i, :2]): int(i) for i in main_ids}
    native_points = shapely.points(vertices[main_ids, :2])
    point_tree = shapely.STRtree(native_points)
    rebuilt = []
    for parent in ids:
        if nav['components'][parent] not in included:
            continue
        # Native polygon rings have T-junctions. Insert all incident vertices
        # before triangulating, otherwise independent parent planes disagree
        # at a ramp endpoint despite sharing the same visible boundary.
        ring = nav['polygons'][parent]
        if stacked:
            polygon = shapely.Polygon(vertices[ring, :2])
            local_lookup = {tuple(vertices[i, :2]): i for i in ring}
            for piece in shapely.get_parts(shapely.constrained_delaunay_triangles(polygon)):
                rebuilt.append([local_lookup[tuple(xy)] for xy in np.asarray(piece.exterior.coords)[:3]])
            continue
        refined_ring = []
        for a, b in zip(ring, ring[1:] + ring[:1]):
            start, end = vertices[a, :2], vertices[b, :2]
            edge = end - start
            nearby = point_tree.query(shapely.LineString([start, end]).buffer(1e-8), predicate='intersects')
            factors = ((vertices[main_ids[nearby], :2] - start) @ edge) / (edge @ edge)
            order = nearby[np.argsort(factors)]
            refined_ring.extend(int(main_ids[i]) for i in order if main_ids[i] != b)
        polygon = shapely.Polygon(vertices[refined_ring, :2])
        for piece in shapely.get_parts(shapely.constrained_delaunay_triangles(polygon)):
            rebuilt.append([lookup[tuple(xy)] for xy in np.asarray(piece.exterior.coords)[:3]])
    triangles = np.array(rebuilt)
    edge_a = vertices[triangles[:, 1], :2] - vertices[triangles[:, 0], :2]
    edge_b = vertices[triangles[:, 2], :2] - vertices[triangles[:, 0], :2]
    areas = np.abs(edge_a[:, 0] * edge_b[:, 1] - edge_a[:, 1] * edge_b[:, 0]) / 2
    triangles = triangles[areas > 1e-10]
    arrangement_report = None
    if stacked:
        vertices, triangles, arrangement_report = lower_arrangement(vertices, triangles, variant)
    surfaces = shapely.polygons(vertices[triangles, :2])
    ground = shapely.union_all(surfaces)
    # A single field cannot use two different elevations at one XY coordinate.
    # Refuse this map until its lower sheet is separated explicitly.
    overlap = float(sum(shapely.area(surfaces)) - ground.area)
    if overlap > 1e-5:
        raise ValueError(f'{map_name}: main sheet overlaps by {overlap} m²; lower-sheet selection required')
    native_bounds = vertices[:, :2].min(0) - 100, vertices[:, :2].max(0) + 100
    rectangle = shapely.box(*native_bounds[0], *native_bounds[1])
    complement = rectangle.difference(ground)
    extensions = shapely.get_parts(shapely.constrained_delaunay_triangles(complement))
    # The constrained triangulation includes all floor boundary coordinates,
    # allowing exact interpolation along original boundary edges.
    edge_counts = {}
    for tri in triangles:
        for a, b in zip(tri, np.roll(tri, -1)):
            key = tuple(sorted((int(a), int(b))))
            edge_counts[key] = edge_counts.get(key, 0) + 1
    boundary_edges = np.array([edge for edge, count in edge_counts.items() if count == 1])
    starts, ends = vertices[boundary_edges[:, 0]], vertices[boundary_edges[:, 1]]
    vectors = ends[:, :2] - starts[:, :2]
    length2 = (vectors * vectors).sum(1)
    points = vertices.tolist()
    lookup = {tuple(vertices[i, :2]): int(i) for i in np.unique(triangles)}
    extension_distances = []
    maximum_boundary_error = 0.
    added = []
    for extension in extensions:
        face = []
        for xy in np.asarray(extension.exterior.coords)[:3]:
            key = tuple(xy)
            if key not in lookup:
                factors = np.clip(((xy - starts[:, :2]) * vectors).sum(1) / length2, 0, 1)
                nearest = starts[:, :2] + factors[:, None] * vectors
                distances = ((nearest - xy) ** 2).sum(1)
                edge = int(np.argmin(distances))
                z = starts[edge, 2] + factors[edge] * (ends[edge, 2] - starts[edge, 2])
                lookup[key] = len(points)
                points.append([*xy, float(z)])
                extension_distances.append(float(np.sqrt(distances[edge])))
                if shapely.distance(shapely.Point(xy), ground.boundary) < 1e-7:
                    maximum_boundary_error = max(maximum_boundary_error, float(np.sqrt(distances[edge])))
            face.append(lookup[key])
        added.append(face)
    all_triangles = np.vstack([triangles, added])
    used, inverse = np.unique(all_triangles, return_inverse=True)
    field_vertices = np.array(points)[used]
    field_triangles = inverse.reshape(-1, 3)
    # Check boundary continuity at shared coordinates, including unused raised
    # platform vertices accidentally present in the original lookup.
    field_surfaces = shapely.polygons(field_vertices[field_triangles, :2])
    covered = shapely.union_all(field_surfaces)
    if covered.symmetric_difference(rectangle).area > 1e-6:
        raise ValueError('Ground field has holes or leaves its declared bounds')
    if sum(shapely.area(field_surfaces)) - covered.area > 1e-5:
        raise ValueError('Ground field interiors overlap')
    field_points = field_vertices[field_triangles]
    planes = np.linalg.solve(np.concatenate([field_points[:, :, :2], np.ones((len(field_triangles), 3, 1))], axis=2),
                             field_points[:, :, 2, None])[:, :, 0]
    field_tree = shapely.STRtree(field_surfaces)
    maximum_continuity_error = 0.
    for point in field_vertices:
        incident = field_tree.query(shapely.Point(point[:2]).buffer(1e-8), predicate='intersects')
        heights = planes[incident, :2] @ point[:2] + planes[incident, 2]
        maximum_continuity_error = max(maximum_continuity_error, float(np.max(np.abs(heights - point[2]), initial=0)))
    if maximum_continuity_error > 1e-5:
        raise ValueError(f'Ground field is discontinuous by {maximum_continuity_error}m')
    result = dict(version=1, coordinateSpace='native-meters',
                  policy='main-continuous-ground-relative-v1' if variant == 'lower' else 'upper-continuous-ground-relative-v1', map=map_name,
                  observerVariant=variant,
                  vertices=field_vertices.reshape(-1).tolist(), triangles=field_triangles.reshape(-1).tolist(),
                  sourceNavigationSha256=hashlib.sha256(nav_bytes).hexdigest(),
                  mainComponent=int(main), sourceTriangles=len(triangles), extensionTriangles=len(added),
                  bounds=[*native_bounds[0], *native_bounds[1]],
                  preservedDisconnectedComponents=len(component_areas) - len(included),
                  maximumExtensionVertexDistanceMeters=max(extension_distances, default=0),
                  maximumGroundBoundaryErrorMeters=maximum_boundary_error,
                  maximumContinuityErrorMeters=maximum_continuity_error,
                  lowerArrangement=arrangement_report,
                  scope='Tactical ramp flattening. Raised disconnected geometry remains above this reference; this is not straight 3D ray equivalence.')
    output.parent.mkdir(parents=True, exist_ok=True)
    encoded = json.dumps(result, separators=(',', ':'), allow_nan=False).encode()
    compressed = gzip.compress(encoded, compresslevel=9, mtime=0)
    output.write_bytes(compressed)
    report = {k: v for k, v in result.items() if k not in ('vertices', 'triangles')}
    report.update(vertices=len(field_vertices), triangles=len(field_triangles), bytes=len(compressed),
                  sha256=hashlib.sha256(compressed).hexdigest(), groundAreaMeters2=ground.area)
    output.with_suffix('.summary.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report), flush=True)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('navigation', type=Path)
    parser.add_argument('catalog', type=Path)
    parser.add_argument('map')
    parser.add_argument('output', type=Path)
    parser.add_argument('--variant', choices=['lower', 'upper'], default='lower')
    args = parser.parse_args()
    build(args.navigation, args.catalog, args.map, args.output, args.variant)
