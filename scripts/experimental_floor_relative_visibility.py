"""Local floor-chart experiment. Never writes production assets.

A chart is one explicitly selected, non-overlapping walkable floor sheet.
Triangles are split at chart boundaries before subtracting the local affine
floor height. Original face IDs and barycentric coordinates survive every cut,
so material classification and alpha UVs can be transferred without guessing.
"""
from dataclasses import dataclass
import numpy as np


@dataclass(frozen=True)
class FloorPatch:
    polygon: np.ndarray
    plane: np.ndarray  # z = a*x + b*y + c, in source meters

    def height(self, xy):
        xy = np.asarray(xy)
        return xy[..., 0] * self.plane[0] + xy[..., 1] * self.plane[1] + self.plane[2]


def validate_chart(patches):
    from shapely.geometry import Polygon
    polygons = [Polygon(p.polygon) for p in patches]
    for polygon in polygons:
        if not polygon.is_valid or polygon.area <= 0 or not polygon.equals(polygon.convex_hull):
            raise ValueError('Floor patches must be convex, non-degenerate polygons.')
    for index, polygon in enumerate(polygons):
        for other in polygons[index + 1:]:
            if polygon.intersection(other).area > 1e-10:
                raise ValueError('Overlapping floors require separate charts, not a highest-floor merge.')
    return polygons


def clip_face_to_patch(triangle, patch):
    """Clip in 3D against an XY prism, retaining original barycentric weights."""
    vertices = [np.r_[p, np.eye(3)[i]] for i, p in enumerate(triangle)]
    polygon = np.asarray(patch.polygon, dtype=float)
    area = np.sum(polygon[:, 0] * np.roll(polygon[:, 1], -1) -
                  polygon[:, 1] * np.roll(polygon[:, 0], -1))
    sign = 1 if area > 0 else -1
    for a, b in zip(polygon, np.roll(polygon, -1, axis=0)):
        clipped = []
        if not vertices:
            break
        edge = b - a
        for start, end in zip(vertices, vertices[1:] + vertices[:1]):
            d0 = sign * (edge[0] * (start[1] - a[1]) - edge[1] * (start[0] - a[0]))
            d1 = sign * (edge[0] * (end[1] - a[1]) - edge[1] * (end[0] - a[0]))
            if d0 >= 0:
                clipped.append(start)
            if (d0 < 0) != (d1 < 0):
                clipped.append(start + (end - start) * (d0 / (d0 - d1)))
        vertices = clipped
    return vertices


def flatten_triangles(triangles, patches):
    """Return split triangles, original face indices, and barycentric weights."""
    validate_chart(patches)
    triangles = np.asarray(triangles, dtype=float).reshape(-1, 3, 3)
    output, source_ids, barycentric = [], [], []
    for patch in patches:
        lower = patch.polygon.min(axis=0)
        upper = patch.polygon.max(axis=0)
        admitted = np.where(np.all(triangles[:, :, :2].max(axis=1) >= lower, axis=1) &
                            np.all(triangles[:, :, :2].min(axis=1) <= upper, axis=1))[0]
        for source_id in admitted:
            clipped = clip_face_to_patch(triangles[source_id], patch)
            for index in range(1, len(clipped) - 1):
                piece = np.array([clipped[0], clipped[index], clipped[index + 1]])
                transformed = piece[:, :3].copy()
                transformed[:, 2] -= patch.height(transformed[:, :2])
                if np.linalg.norm(np.cross(transformed[1] - transformed[0],
                                           transformed[2] - transformed[0])) < 1e-14:
                    continue
                output.append(transformed)
                source_ids.append(source_id)
                barycentric.append(piece[:, 3:])
    return (np.array(output).reshape(-1, 3, 3), np.array(source_ids, dtype=np.int64),
            np.array(barycentric).reshape(-1, 3, 3))


def first_hit(triangles, start, end, transparent=None):
    """Independent double-precision finite 3D ray cast, returning source t/index."""
    triangles = np.asarray(triangles, dtype=float).reshape(-1, 3, 3)
    start, end = np.asarray(start, dtype=float), np.asarray(end, dtype=float)
    direction = end - start
    edge1 = triangles[:, 1] - triangles[:, 0]
    edge2 = triangles[:, 2] - triangles[:, 0]
    p = np.cross(np.broadcast_to(direction, edge2.shape), edge2)
    determinant = np.einsum('ij,ij->i', edge1, p)
    valid = np.abs(determinant) > 1e-12
    inverse = np.zeros(len(triangles))
    inverse[valid] = 1 / determinant[valid]
    difference = start - triangles[:, 0]
    u = np.einsum('ij,ij->i', difference, p) * inverse
    q = np.cross(difference, edge1)
    v = q @ direction * inverse
    t = np.einsum('ij,ij->i', edge2, q) * inverse
    valid &= (u >= -1e-10) & (v >= -1e-10) & (u + v <= 1 + 1e-10) & (t > 1e-8) & (t < 1 - 1e-8)
    for index in np.where(valid)[0][np.argsort(t[valid])]:
        weights = np.array([1 - u[index] - v[index], u[index], v[index]])
        if transparent is None or not transparent(int(index), weights):
            return float(t[index]), int(index)
    return None


def rectangle(x0, x1, y0=-2, y1=2):
    return np.array([[x0, y0], [x1, y0], [x1, y1], [x0, y1]], dtype=float)


def surface(patch, offset=0):
    points = np.c_[patch.polygon, patch.height(patch.polygon) + offset]
    return np.array([[points[0], points[1], points[2]], [points[0], points[2], points[3]]])


def wall(x, floor, height, y0=-2, y1=2):
    points = np.array([[x, y0, floor], [x, y1, floor],
                       [x, y1, floor + height], [x, y0, floor + height]])
    return np.array([[points[0], points[1], points[2]], [points[0], points[2], points[3]]])
