"""Offline opaque profile shadows on a standing-height receiver plane.

Each original-height triangle defines a convex shadow volume: three planes
through its edges and the eye, plus its own plane facing away from the eye.
Intersect that volume with a finite convex target-floor footprint. No per-pixel
ray casting is used to construct the result. Coplanar eyes need a separate
contact policy and are reported, never silently accepted as clear.
"""
from dataclasses import dataclass
import numpy as np


@dataclass
class Receiver:
    footprint: np.ndarray
    floor_plane: np.ndarray
    standing_height: float = 1.75

    def lift(self, xy):
        xy = np.asarray(xy, dtype=float)
        return np.concatenate([xy, (xy @ self.floor_plane[:2] +
                                    self.floor_plane[2] + self.standing_height)[..., None]], axis=-1)


def clip(polygon, coefficients):
    """Keep a*x+b*y+c >= 0, including geometric contact boundaries."""
    if not len(polygon):
        return polygon
    output = []
    previous = polygon[-1]
    fp = previous @ coefficients[:2] + coefficients[2]
    for current in polygon:
        fc = current @ coefficients[:2] + coefficients[2]
        if (fp >= 0) != (fc >= 0):
            output.append(previous + (current - previous) * (fp / (fp - fc)))
        if fc >= 0:
            output.append(current)
        previous, fp = current, fc
    return np.asarray(output, dtype=float).reshape(-1, 2)


def shadow_triangle(eye, triangle, receiver):
    eye = np.asarray(eye, dtype=float)
    triangle = np.asarray(triangle, dtype=float)
    edge1, edge2 = triangle[1] - triangle[0], triangle[2] - triangle[0]
    face_normal = np.cross(edge1, edge2)
    normal_length = np.linalg.norm(face_normal)
    if normal_length == 0:
        return None, 'degenerate-source-triangle'
    eye_distance = np.dot(face_normal, eye - triangle[0])
    # Explicit bounded fallback band; no claim that this is a full error bound.
    if abs(eye_distance) <= 1e-10 * normal_length:
        return None, 'observer-coplanar-contact-requires-source-fallback'
    # Filter an uncertain orientation instead of assigning independent signs
    # to edge planes. Tiny faces are retained as explicit fallback identities.
    permanent_normal = np.abs(edge1[[1, 2, 0]] * edge2[[2, 0, 1]]) + np.abs(edge1[[2, 0, 1]] * edge2[[1, 2, 0]])
    determinant_bound = 32 * np.finfo(float).eps * np.dot(permanent_normal, np.abs(eye - triangle[0]))
    if abs(eye_distance) <= determinant_bound:
        return None, 'uncertain-orientation-requires-source-fallback'
    planes = []
    for index in range(3):
        a, b = triangle[index], triangle[(index + 1) % 3]
        normal = np.cross(a - eye, b - a)
        # All three scalar triple products have the same orientation. Reusing
        # the face determinant avoids cancellation in (C-eye) dot edgeNormal.
        if eye_distance > 0:
            normal = -normal
        planes.append((normal, 0.))
    normal = -face_normal if eye_distance > 0 else face_normal
    planes.append((normal, -abs(eye_distance)))
    # Construct and evaluate planes around the eye. World offsets previously
    # cancelled a thin wall's side constraint into a whole-receiver shadow.
    polygon = np.asarray(receiver.footprint, dtype=float) - eye[:2]
    a, b, c = receiver.floor_plane
    height_offset = a * eye[0] + b * eye[1] + c + receiver.standing_height - eye[2]
    for normal, offset in planes:
        coefficients = np.array([normal[0] + normal[2] * a,
                                 normal[1] + normal[2] * b,
                                 offset + normal[2] * height_offset])
        polygon = clip(polygon, coefficients)
        if not len(polygon):
            break
    return polygon + eye[:2], None


def build_shadows(eye, triangles, receivers):
    polygons, unresolved = [], []
    for receiver_id, receiver in enumerate(receivers):
        for face, triangle in enumerate(triangles):
            polygon, reason = shadow_triangle(eye, triangle, receiver)
            if reason:
                unresolved.append(dict(receiver=receiver_id, sourceFace=face, reason=reason))
            elif len(polygon) and len(polygon) < 3:
                unresolved.append(dict(receiver=receiver_id, sourceFace=face,
                                       reason='point-or-edge-contact-requires-source-fallback'))
            elif len(polygon) >= 3:
                # Positive-area shadow triangles use the renderer's existing
                # source-XY-relative-to-eye contract. Point contacts stay explicit.
                local = polygon - polygon[0]
                area2 = abs(np.sum(local[:, 0] * np.roll(local[:, 1], -1) -
                                   local[:, 1] * np.roll(local[:, 0], -1)))
                if area2 > 1e-16:
                    polygons.append(dict(receiver=receiver_id, sourceFace=face, polygon=polygon))
                else:
                    unresolved.append(dict(receiver=receiver_id, sourceFace=face,
                                           reason='zero-or-small-area-contact-requires-source-fallback'))
    return polygons, unresolved


def renderer_mesh(eye, polygons):
    """Legacy unchecked diagnostic conversion; use checked API for rendering."""
    triangles = []
    for row in polygons:
        polygon = row['polygon'] - np.asarray(eye[:2])
        for i in range(1, len(polygon) - 1):
            triangles.append(polygon[[0, i, i + 1]])
    return np.asarray(triangles, dtype=np.float32).reshape(-1, 3, 2)


def renderer_mesh_checked(eye, polygons):
    """Keep every unrepresentable source face as an explicit fallback.

    Float32 output may collapse or reverse a thin triangle even when clipping
    produced a valid double polygon. A partial fan cannot represent that face:
    retain its identity and emit none of its triangles in the resolved mesh.
    """
    triangles, unresolved = [], []
    for row in polygons:
        polygon = np.asarray(row['polygon'], dtype=float)-np.asarray(eye[:2])
        fan = []
        reason = None
        for i in range(1, len(polygon)-1):
            tri = polygon[[0, i, i+1]]
            a, b = tri[1]-tri[0], tri[2]-tri[0]
            area = a[0]*b[1]-a[1]*b[0]
            if area == 0:
                continue
            with np.errstate(over='ignore', invalid='ignore'):
                output = tri.astype(np.float32)
                quantized = output.astype(float)
                a, b = quantized[1]-quantized[0], quantized[2]-quantized[0]
                quantized_area = a[0]*b[1]-a[1]*b[0]
            if (not np.isfinite(area) or not np.isfinite(output).all() or
                    not np.isfinite(quantized_area) or quantized_area == 0 or
                    (quantized_area > 0) != (area > 0)):
                reason = 'float32-collapse-or-orientation-loss-requires-source-fallback'
                break
            fan.append(output)
        if reason or not fan:
            unresolved.append(dict(receiver=row['receiver'], sourceFace=row['sourceFace'],
                                   reason=reason or 'point-or-edge-contact-requires-source-fallback'))
        else:
            triangles.extend(fan)
    return np.asarray(triangles, dtype=np.float32).reshape(-1, 3, 2), unresolved
