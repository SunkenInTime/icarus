"""Compose two local XY warps exactly, before geometry/navigation quantization."""
import argparse
import json
from pathlib import Path

import numpy as np
import shapely

from tactical_alignment_candidate import Warp
from tactical_alignment_cells import clip_triangle, cross


class IndexedTriangles:
    def __init__(self, points, triangles):
        self.simplices = np.array(triangles, dtype=int)
        xyz = points[self.simplices]
        self.polygons = shapely.polygons(xyz)
        self.tree = shapely.STRtree(self.polygons)
        self.transform = np.zeros((len(xyz), 3, 2))
        self.transform[:, :2] = np.linalg.inv(np.stack((xyz[:, 0] - xyz[:, 2], xyz[:, 1] - xyz[:, 2]), axis=2))
        self.transform[:, 2] = xyz[:, 2]
        self.neighbors = np.full((len(triangles), 3), -1, dtype=int)
        edges = {}
        for cell, ids in enumerate(self.simplices):
            for edge in range(3):
                key = tuple(sorted((ids[edge], ids[(edge + 1) % 3])))
                if key in edges:
                    other, other_edge = edges[key]
                    self.neighbors[cell, edge] = other
                    self.neighbors[other, other_edge] = cell
                else:
                    edges[key] = (cell, edge)

    def find_simplex(self, xy, tol=None):
        xy = np.asarray(xy)
        single = xy.ndim == 1
        rows = np.atleast_2d(xy)
        result = np.full(len(rows), -1, dtype=int)
        point_ids, cells = self.tree.query(shapely.points(rows), predicate='intersects')
        result[point_ids] = cells
        # Shared-edge arithmetic can leave a point a few ulps beyond a triangle.
        missing = np.flatnonzero(result < 0)
        if len(missing):
            closest = self.tree.nearest(shapely.points(rows[missing]))
            distances = shapely.distance(shapely.points(rows[missing]), self.polygons[closest])
            admitted = distances <= 1e-9
            result[missing[admitted]] = closest[admitted]
        return int(result[0]) if single else result


def explicit_warp(points, delta, triangles):
    warp = object.__new__(Warp)
    warp.points, warp.delta = np.array(points), np.array(delta)
    warp.tri = IndexedTriangles(warp.points, triangles)
    before = warp.points[warp.tri.simplices]
    after = before + warp.delta[warp.tri.simplices]
    determinant = lambda a: (a[:, 1, 0] - a[:, 0, 0]) * (a[:, 2, 1] - a[:, 0, 1]) - (a[:, 1, 1] - a[:, 0, 1]) * (a[:, 2, 0] - a[:, 0, 0])
    warp.jacobians = determinant(after) / determinant(before)
    return warp


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--second', type=Path, required=True)
    parser.add_argument('--first', type=Path)
    parser.add_argument('--map', default='split')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    from tactical_alignment_warps import load_warp
    first, second = load_warp(args.first) if args.first else Warp(), load_warp(args.second)
    active = np.any(np.linalg.norm(second.delta[second.tri.simplices], axis=2) > 0, axis=1)
    cells = second.points[second.tri.simplices[active]]
    lower, upper = cells.min(1), cells.max(1)
    domain = shapely.union_all(shapely.polygons(cells))
    vertices, deltas, triangles, lookup = [], [], [], {}
    maximum_area_error = 0.
    for ids in first.tri.simplices:
        before = first.points[ids]
        middle = before + first.delta[ids]
        original_area = abs(cross(before[1] - before[0], before[2] - before[0])) / 2
        parts = []
        for cell in np.flatnonzero(np.all(upper >= middle.min(0), axis=1) & np.all(lower <= middle.max(0), axis=1)):
            bary = clip_triangle(middle, cells[cell])
            parts.extend(np.array([bary[0], bary[i], bary[i + 1]]) for i in range(1, len(bary) - 1))
        remainder = shapely.Polygon(middle).difference(domain)
        if not remainder.is_empty:
            source_matrix = np.vstack((middle.T, np.ones(3)))
            for triangle in shapely.constrained_delaunay_triangles(remainder).geoms:
                points = np.array(triangle.exterior.coords)[:3]
                parts.append(np.linalg.solve(source_matrix, np.vstack((points.T, np.ones(3)))).T)
        covered = 0.
        for bary in parts:
            points = bary @ before
            area = abs(cross(points[1] - points[0], points[2] - points[0])) / 2
            if area < 1e-10:
                continue
            target = second.apply(bary @ middle)
            indices = []
            for point, to in zip(points, target):
                key = tuple(np.round(point, 10))
                if key not in lookup:
                    lookup[key] = len(vertices)
                    vertices.append(point)
                    deltas.append(to - point)
                indices.append(lookup[key])
            triangles.append(indices)
            covered += area
        maximum_area_error = max(maximum_area_error, abs(covered - original_area) / original_area)
    warp = explicit_warp(vertices, deltas, triangles)
    samples = warp.points[warp.tri.simplices].mean(1)
    expected = second.apply(first.apply(samples))
    error = float(np.linalg.norm(warp.apply(samples) - expected, axis=1).max())
    if error > 1e-8 or maximum_area_error > 1e-8 or warp.jacobians.min() <= .5:
        raise ValueError(f'Composition failed: {error}, {maximum_area_error}, {warp.jacobians.min()}')
    args.output.mkdir(parents=True, exist_ok=False)
    np.savez_compressed(args.output / 'warp.npz', points=warp.points, displacements=warp.delta,
                        triangles=warp.tri.simplices, explicitTriangles=np.array([1]))
    report = {'format': 'icarus-composed-xy-warp-v1', 'map': args.map, 'adopted': False,
              'first': str(args.first) if args.first else 'Original manual Deadlock/Iso Warp', 'second': str(args.second),
              'triangles': len(triangles), 'minimumCellJacobian': float(warp.jacobians.min()),
              'maximumCellJacobian': float(warp.jacobians.max()), 'maximumCompositionErrorSvg': error,
              'maximumSourceAreaRelativeError': maximum_area_error}
    (args.output / 'candidate.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
