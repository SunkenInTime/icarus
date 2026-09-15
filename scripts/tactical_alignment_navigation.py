"""Preserve navigation domains/connectivity under a piecewise-affine XY warp."""
import copy
from collections import defaultdict

import numpy as np
from shapely import LineString, Polygon, constrained_delaunay_triangles, union_all

from tactical_alignment_cells import clip_triangle, cross


def warp_navigation(source, uv_to_svg, svg_to_uv, warp, local_only=True):
    nav = copy.deepcopy(source)
    if not np.any(warp.delta):
        nav['sourcePolygonIds'] = source.get('sourcePolygonIds', list(range(len(source['polygons']))))
        return nav, {'originalPolygons': len(source['polygons']), 'candidatePolygons': len(source['polygons']),
                     'candidateLinks': len(source['links']) // 6,
                     'candidateDetailTriangles': len(source['floorMesh']['triangles']) // 4,
                     'unreachableInternalParents': [], 'missingOriginalPortalPairs': [], 'newUnauthorizedParentPairs': [],
                     'maximumDetailAffineCentroidErrorSvg': 0., 'relativeFloorAreaDifference': 0.,
                     'quantizedNavAreaLossSvg2': 0., 'identityWarpPreservesSourceArrays': True}
    target_scale = max(source['coordinateScale'], 1000000000)
    original = np.array(source['vertices'], dtype=float).reshape(-1, 3)
    xy = uv_to_svg(original[:, :2] / source['coordinateScale'])
    refined = np.array(source['refinedFloorHeightsCm'], dtype=float)
    original[:, 2] = np.where(np.isnan(refined), original[:, 2], refined)
    original_nav_triangles = defaultdict(list)
    for parent, a, b, c in np.array(source['triangles']).reshape(-1, 4):
        original_nav_triangles[int(parent)].append([int(a), int(b), int(c)])
    # Exported helper triangles can overlap inside a parent. Partition the actual
    # polygon boundary; constrained triangulation uses its existing vertices.
    cells = warp.points[warp.tri.simplices]
    cell_lo, cell_hi = cells.min(1), cells.max(1)
    active = np.any(np.linalg.norm(warp.delta[warp.tri.simplices], axis=2) > 0, axis=1)
    active_domain = union_all([Polygon(cell) for cell in cells[active]])
    unchanged_parents = set()
    triangles = []
    work = []
    for parent, indices in enumerate(source['polygons']):
        if local_only and Polygon(xy[indices]).intersection(active_domain).area < 1e-10:
            unchanged_parents.add(parent)
            work.append((parent, list(indices), -1, np.eye(len(indices))))
            continue
        outline = original[indices, :2]
        lookup = {tuple(point): index for point, index in zip(outline, indices)}
        for triangle in constrained_delaunay_triangles(Polygon(outline)).geoms:
            triangles.append([parent, *[lookup[tuple(point)] for point in list(triangle.exterior.coords)[:3]]])
    for parent, a, b, c in triangles:
        source_ids = [a, b, c]
        points = xy[source_ids]
        for cell_id in np.flatnonzero(np.all(cell_hi >= points.min(0), axis=1) & np.all(cell_lo <= points.max(0), axis=1)):
            bary = clip_triangle(points, cells[cell_id])
            if len(bary) >= 3:
                work.append((parent, source_ids, cell_id, np.array(bary)))
    children = []
    by_parent = defaultdict(list)
    vertices, polys, nav_tris, heights = [], [], [], []
    quantization_area_loss = 0.
    for parent, source_ids, cell_id, bary in work:
        points = xy[source_ids]
        polygon_xy = bary @ points
        # Consecutive duplicates can appear when a source vertex lies on a cell edge.
        keep = (np.ones(len(polygon_xy), dtype=bool) if parent in unchanged_parents else
                np.linalg.norm(polygon_xy - np.roll(polygon_xy, 1, axis=0), axis=1) > 1e-9)
        bary, polygon_xy = bary[keep], polygon_xy[keep]
        if len(bary) < 3:
            continue
        shape = Polygon(polygon_xy)
        if shape.area < 1e-8:
            continue
        target_uv = (np.rint(original[source_ids, :2] * (target_scale / source['coordinateScale'])).astype(np.int64)
                     if parent in unchanged_parents else
                     np.rint(svg_to_uv(warp.apply(polygon_xy)) * target_scale).astype(np.int64))
        # Native navigation triangles reject numeric slivers after UV encoding.
        distinct = np.linalg.norm(target_uv - np.roll(target_uv, 1, axis=0), axis=1) > 0
        bary, polygon_xy, target_uv = bary[distinct], polygon_xy[distinct], target_uv[distinct]
        if len(bary) < 3:
            quantization_area_loss += shape.area
            continue
        child = len(children)
        first = len(vertices)
        z = bary @ original[source_ids, 2]
        indices = list(range(first, first + len(target_uv)))
        vertices.extend([[int(u), int(v), float(h)] for (u, v), h in zip(target_uv, z)])
        heights.extend(z.tolist())
        polys.append(indices)
        if parent in unchanged_parents:
            lookup = dict(zip(source_ids, indices))
            # Recast helper triangles can reference interior vertices absent
            # from the polygon boundary. Retain those exact source coordinates.
            for triangle in original_nav_triangles[parent]:
                for index in triangle:
                    if index not in lookup:
                        lookup[index] = len(vertices)
                        uv = np.rint(original[index, :2] * (target_scale / source['coordinateScale'])).astype(np.int64)
                        vertices.append([int(uv[0]), int(uv[1]), float(original[index, 2])])
                        heights.append(float(original[index, 2]))
            nav_tris.extend([child, *[lookup[index] for index in triangle]]
                            for triangle in original_nav_triangles[parent])
        else:
            for i in range(1, len(indices) - 1):
                if abs(cross(target_uv[i] - target_uv[0], target_uv[i + 1] - target_uv[0])) < 1e-6:
                    continue
                nav_tris.append([child, indices[0], indices[i], indices[i + 1]])
        # Detailed floors must meet the encoded parent boundary, not its
        # pre-quantization position, or an edge point can fall through to a
        # coarse fallback height in the neighboring child polygon.
        if parent in unchanged_parents:
            floor_outline = polygon_xy
        else:
            source_cell = cells[cell_id]
            target_cell = source_cell + warp.delta[warp.tri.simplices[cell_id]]
            target_matrix = np.column_stack((target_cell[0] - target_cell[2], target_cell[1] - target_cell[2]))
            weights2 = (uv_to_svg(target_uv / target_scale) - target_cell[2]) @ np.linalg.inv(target_matrix).T
            weights3 = np.column_stack((weights2, 1 - weights2.sum(1)))
            floor_outline = weights3 @ source_cell
        children.append({'parent': int(parent), 'cell': int(cell_id), 'shape': Polygon(polygon_xy), 'points': polygon_xy,
                         'floorOutline': floor_outline})
        by_parent[int(parent)].append(child)
    # Only introduce portals inside one original polygon or along an existing
    # authorized native portal. Nearby disconnected floors remain disconnected.
    links, links_seen = [], set()
    def connect(left, right, geometry):
        parts = list(geometry.geoms) if hasattr(geometry, 'geoms') else [geometry]
        for part in parts:
            if part.geom_type != 'LineString' or part.length < 1e-6:
                continue
            points = np.array([part.coords[0], part.coords[-1]])
            warped = np.rint(svg_to_uv(warp.apply(points)) * target_scale).astype(np.int64)
            if np.array_equal(warped[0], warped[1]):
                continue
            key = (min(left, right), max(left, right), *sorted(map(tuple, warped.tolist())))
            if key in links_seen:
                continue
            links_seen.add(key)
            links.append([left, right, *warped.ravel().tolist()])
            links.append([right, left, *warped.ravel().tolist()])
    for parent, ids in by_parent.items():
        if not source['walkable'][parent]:
            continue
        for i, left in enumerate(ids):
            for right in ids[i + 1:]:
                shared = children[left]['shape'].boundary.intersection(children[right]['shape'].boundary.buffer(1e-8))
                connect(left, right, shared)
    original_links = np.array(source['links'], dtype=float).reshape(-1, 6)
    for row in original_links:
        parent_a, parent_b = map(int, row[:2])
        if parent_a >= parent_b:
            continue
        portal = LineString(uv_to_svg(row[2:].reshape(2, 2) / source['coordinateScale']))
        for left in by_parent[parent_a]:
            for right in by_parent[parent_b]:
                # A tiny buffer handles source UV endpoint rounding, then the
                # portal itself bounds every admitted new edge.
                shared = portal.intersection(children[left]['shape'].buffer(1e-7)).intersection(children[right]['shape'].buffer(1e-7))
                connect(left, right, shared)
    nav['vertices'] = [v for vertex in vertices for v in vertex]
    nav['coordinateScale'] = target_scale
    nav['refinedFloorHeightsCm'] = heights
    nav['polygons'] = polys
    nav['triangles'] = [v for triangle in nav_tris for v in triangle]
    nav['links'] = [v for link in links for v in link]
    nav['components'] = [source['components'][child['parent']] for child in children]
    nav['walkable'] = [source['walkable'][child['parent']] for child in children]
    source_parent_ids = source.get('sourcePolygonIds', list(range(len(source['polygons']))))
    nav['sourcePolygonIds'] = [source_parent_ids[child['parent']] for child in children]
    if 'tacticalGroundChartIds' in source:
        chart_ids = source['tacticalGroundChartIds']
        if len(chart_ids) != len(source['polygons']) or any(not isinstance(value, int) or value < 0 for value in chart_ids):
            raise ValueError('Invalid source tactical ground chart selectors')
        nav['tacticalGroundChartIds'] = [chart_ids[child['parent']] for child in children]
    original_floor = source['floorMesh']
    floor_vertices = np.array(original_floor['vertices'], dtype=float).reshape(-1, 3)
    floor_xy = uv_to_svg(floor_vertices[:, :2] / original_floor['coordinateScale'])
    floor_rows = np.array(original_floor['triangles'], dtype=int).reshape(-1, 4)
    target_vertices, target_triangles = [], []
    unchanged_floor_triangles = 0
    original_floor_area, covered_floor_area = 0., 0.
    max_cell_error = 0.
    for parent, a, b, c in floor_rows:
        source_ids = [a, b, c]
        points = floor_xy[source_ids]
        area = abs(cross(points[1] - points[0], points[2] - points[0])) / 2
        original_floor_area += area
        if int(parent) in unchanged_parents:
            child = by_parent[int(parent)][0]
            first = len(target_vertices)
            target_vertices.extend(floor_vertices[source_ids].tolist())
            target_triangles.append([child, first, first + 1, first + 2])
            covered_floor_area += area
            unchanged_floor_triangles += 1
            continue
        for child in by_parent[int(parent)]:
            outline = children[child]['floorOutline']
            if np.any(outline.max(0) < points.min(0)) or np.any(outline.min(0) > points.max(0)):
                continue
            bary = clip_triangle(points, outline)
            if len(bary) < 3:
                continue
            for i in range(1, len(bary) - 1):
                weights = np.array([bary[0], bary[i], bary[i + 1]])
                triangle_xy = weights @ points
                area = abs(cross(triangle_xy[1] - triangle_xy[0], triangle_xy[2] - triangle_xy[0])) / 2
                if area < 1e-12:
                    continue
                target_xy = warp.apply(triangle_xy)
                # Keep interpolation intersections as doubles. Independently
                # rounding them can move a diagonal floor edge off its parent.
                encoded = svg_to_uv(target_xy) * original_floor['coordinateScale']
                if abs(cross(encoded[1] - encoded[0], encoded[2] - encoded[0])) < 1:
                    continue
                first = len(target_vertices)
                z = weights @ floor_vertices[source_ids, 2]
                target_vertices.extend([[float(u), float(v), float(h)] for (u, v), h in zip(encoded, z)])
                target_triangles.append([child, first, first + 1, first + 2])
                covered_floor_area += area
                max_cell_error = max(max_cell_error, float(np.linalg.norm(target_xy.mean(0) - warp.apply(triangle_xy.mean(0)))))
    if local_only:
        # Preserve first occurrence and compare exact IEEE bits. This removes
        # per-face duplication without rounding interpolated floor intersections.
        floor_array = np.ascontiguousarray(target_vertices, dtype=np.float64)
        _, first, inverse = np.unique(floor_array.view(np.dtype((np.void, 24))).reshape(-1),
                                      return_index=True, return_inverse=True)
        order = np.argsort(first)
        rank = np.empty_like(order)
        rank[order] = np.arange(len(order))
        rows = np.array(target_triangles, dtype=np.int64)
        rows[:, 1:] = rank[inverse[rows[:, 1:]]]
        compact = floor_array[first[order]]
        # All output triangle coordinates, including unchanged source details,
        # must remain bit-identical after deduplication.
        if not np.array_equal(compact[rows[:, 1:]].view(np.uint64),
                              floor_array[np.array(target_triangles)[:, 1:]].view(np.uint64)):
            raise ValueError('Floor deduplication changed a triangle')
        target_vertices, target_triangles = compact.tolist(), rows.tolist()
    nav['floorMesh'] = {'coordinateScale': original_floor['coordinateScale'],
                        'vertices': [v for vertex in target_vertices for v in vertex],
                        'triangles': [v for triangle in target_triangles for v in triangle]}
    # Every original portal must retain a route through its child subdivisions.
    adjacency = defaultdict(set)
    for left, right, *_ in links:
        adjacency[left].add(right)
    unreachable_parents = []
    for parent, ids in by_parent.items():
        if not source['walkable'][parent]:
            continue
        admitted = set(ids)
        reached, pending = {ids[0]}, [ids[0]]
        while pending:
            for neighbor in adjacency[pending.pop()] & admitted - reached:
                reached.add(neighbor)
                pending.append(neighbor)
        if len(reached) != len(ids):
            unreachable_parents.append(parent)
    preserved_pairs = {tuple(sorted((children[a]['parent'], children[b]['parent']))) for a, b, *_ in links if children[a]['parent'] != children[b]['parent']}
    original_pairs = {tuple(sorted(map(int, row[:2]))) for row in original_links}
    proof = {'originalPolygons': len(source['polygons']), 'candidatePolygons': len(polys), 'candidateLinks': len(links),
             'candidateDetailTriangles': len(target_triangles), 'unreachableInternalParents': unreachable_parents,
             'missingOriginalPortalPairs': sorted(original_pairs - preserved_pairs),
             'newUnauthorizedParentPairs': sorted(preserved_pairs - original_pairs),
             'maximumDetailAffineCentroidErrorSvg': max_cell_error,
             'originalFloorAreaSvg2': original_floor_area, 'coveredFloorAreaSvg2': covered_floor_area,
             'relativeFloorAreaDifference': abs(covered_floor_area - original_floor_area) / original_floor_area,
             'quantizedNavAreaLossSvg2': quantization_area_loss}
    proof.update({'localOnly': local_only, 'unchangedSourceParents': len(unchanged_parents),
                  'unchangedSourceFloorTriangles': unchanged_floor_triangles,
                  'floorDeduplicationPreservesTriangleBits': local_only})
    return nav, proof
