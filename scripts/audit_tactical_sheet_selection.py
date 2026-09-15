"""Seed floor branches from real overlaps and extend them through nav portals."""
import argparse
import gzip
import heapq
import json
from pathlib import Path
import numpy as np
import shapely
from build_global_tactical_candidate import GroundField


def audit(revision, map_name):
    nav = json.loads(gzip.decompress((revision / 'baseline-world' / (map_name + '_navigation.json.gz')).read_bytes()))
    ui = json.loads(Path('assets/maps/world/height_catalog.json').read_text())['maps'][map_name]['uiTransform']
    vertices = np.array(nav['vertices'], dtype=float).reshape(-1, 3)
    uv = vertices[:, :2] / nav['coordinateScale']
    vertices[:, 0] = (uv[:, 1] - ui['YScalarToAdd']) / (100 * ui['YMultiplier'])
    vertices[:, 1] = -(uv[:, 0] - ui['XScalarToAdd']) / (100 * ui['XMultiplier'])
    vertices[:, 2] = np.array(nav['refinedFloorHeightsCm']) / 100
    ids = np.flatnonzero(nav['walkable'])
    polygons = np.array([shapely.Polygon(vertices[nav['polygons'][i], :2]) for i in ids])
    tree = shapely.STRtree(polygons)
    centers = np.array([vertices[p].mean(0) for p in nav['polygons']])
    triangles = {}
    for parent in ids:
        ring = nav['polygons'][parent]
        lookup = {tuple(vertices[i, :2]): i for i in ring}
        polygon = shapely.Polygon(vertices[ring, :2])
        triangles[int(parent)] = [vertices[[lookup[tuple(xy)] for xy in np.array(piece.exterior.coords)[:3]]]
                                  for piece in shapely.get_parts(shapely.constrained_delaunay_triangles(polygon))]
    def height(parent, xy):
        for tri in triangles[parent]:
            if shapely.Polygon(tri[:, :2]).buffer(1e-8).covers(shapely.Point(xy)):
                plane = np.linalg.solve(np.c_[tri[:, :2], np.ones(3)], tri[:, 2])
                return float(np.r_[xy, 1] @ plane)
        raise ValueError('No parent height')
    cells = shapely.get_parts(shapely.polygonize(shapely.get_parts(shapely.union_all(shapely.boundary(polygons)))))
    main = json.loads(gzip.decompress((revision / 'global-ground-v1' / (map_name + '.tactical-ground.json.gz')).read_bytes()))['mainComponent']
    seeds = [set(), set()]
    overlap_cells = []
    maximum_levels, maximum_main_levels = 1, 1
    for cell in cells:
        point = cell.representative_point()
        parents = ids[tree.query(point, predicate='intersects')]
        if len(parents) < 2:
            continue
        xy = np.array([point.x, point.y])
        ordered = sorted((height(int(parent), xy), int(parent)) for parent in parents)
        groups = []
        for z, parent in ordered:
            if not groups or z - groups[-1][0] > .35:
                groups.append([z, [parent]])
            else:
                groups[-1][1].append(parent)
        maximum_levels = max(maximum_levels, len(groups))
        main_groups = [(z, [parent for parent in group if nav['components'][parent] == main]) for z, group in groups]
        main_groups = [(z, group) for z, group in main_groups if group]
        maximum_main_levels = max(maximum_main_levels, len(main_groups))
        if len(main_groups) >= 2:
            seeds[0].update(main_groups[0][1])
            seeds[1].update(main_groups[-1][1])
            overlap_cells.append(dict(point=xy.tolist(), levels=main_groups, areaMeters2=cell.area))
    adjacency = [[] for _ in nav['polygons']]
    for start, end, *_ in np.array(nav['links']).reshape(-1, 6):
        a, b = int(start), int(end)
        distance = float(np.linalg.norm(centers[a] - centers[b]))
        adjacency[a].append((b, distance))
    distances = []
    for branch_seeds in seeds:
        costs = np.full(len(adjacency), np.inf)
        heap = [(0., node) for node in branch_seeds]
        heapq.heapify(heap)
        for node in branch_seeds:
            costs[node] = 0
        while heap:
            cost, node = heapq.heappop(heap)
            if cost != costs[node]:
                continue
            for neighbor, weight in adjacency[node]:
                candidate = cost + weight
                if candidate < costs[neighbor]:
                    costs[neighbor] = candidate
                    heapq.heappush(heap, (candidate, neighbor))
        distances.append(costs)
    labels = np.where(distances[1] < distances[0], 1, 0)
    boundaries = []
    for a, neighbors in enumerate(adjacency):
        for b, _ in neighbors:
            if a < b and labels[a] != labels[b]:
                boundaries.append(dict(parents=[a, b], centers=[centers[a].tolist(), centers[b].tolist()]))
    report = dict(map=map_name, maximumOverlappingLevels=maximum_levels, maximumMainComponentLevels=maximum_main_levels,
                  lowerSeedParents=sorted(seeds[0]), upperSeedParents=sorted(seeds[1]), conflictingSeedParents=sorted(seeds[0] & seeds[1]),
                  parentVariants=labels.tolist(), variantBoundaryPortals=boundaries, overlapCells=overlap_cells,
                  policy='Nearest overlap-branch seed by 3D nav portal graph distance; ties default lower. Experimental; crossings require continuity audit.')
    upper_path = revision / 'upper-ground-v2' / (map_name + '.tactical-ground.json.gz')
    if upper_path.exists():
        lower, upper = GroundField(revision / 'global-ground-v1' / (map_name + '.tactical-ground.json.gz')), GroundField(upper_path)
        values = centers[ids, :2]
        lo, hi = lower.heights(values), upper.heights(values)
        equal = (np.abs(hi - lo) < 1e-5) & (labels[ids] == 1) & (distances[1][ids] < 20)
        candidates = ids[equal]
        report['upperApproachesWithEqualOriginReferences'] = [dict(parent=int(p), origin=centers[p].tolist(),
                seedDistanceMeters=float(distances[1][p]), lowerReference=float(lower.heights(centers[p:p + 1, :2])[0]))
                for p in candidates[np.argsort(distances[1][candidates])][:20]]
    output = revision / 'sheet-selection-v1' / (map_name + '.json')
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + '\n')
    print(map_name, 'levels', maximum_levels, 'mainLevels', maximum_main_levels, 'seeds', list(map(len, seeds)), 'conflicts', len(seeds[0] & seeds[1]), 'boundaries', len(boundaries), flush=True)
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('revision', type=Path)
    parser.add_argument('maps', nargs='+')
    args = parser.parse_args()
    for name in args.maps:
        audit(args.revision, name)
