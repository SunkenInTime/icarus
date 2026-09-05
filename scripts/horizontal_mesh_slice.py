"""Intersect placed triangles with a horizontal plane, preserving source faces."""
import numpy as np


def slice_triangles(triangles, elevation, epsilon=1e-8):
    triangles = np.asarray(triangles, dtype=float)
    offsets = triangles[:, :, 2] - elevation
    candidates = np.flatnonzero((offsets.min(axis=1) <= epsilon) &
                               (offsets.max(axis=1) >= -epsilon))
    segments, owners, coplanar = [], [], 0
    for index in candidates:
        triangle, dz = triangles[index], offsets[index]
        if np.all(np.abs(dz) <= epsilon):
            coplanar += 1
            edges = [(triangle[i, :2], triangle[(i + 1) % 3, :2]) for i in range(3)]
        else:
            points = []
            for i in range(3):
                j = (i + 1) % 3
                if abs(dz[i]) <= epsilon:
                    points.append(triangle[i, :2])
                if dz[i] * dz[j] < 0:
                    t = -dz[i] / (dz[j] - dz[i])
                    points.append((triangle[i] + t * (triangle[j] - triangle[i]))[:2])
            unique = []
            for point in points:
                if not any(np.linalg.norm(point - p) <= epsilon for p in unique):
                    unique.append(point)
            edges = [(unique[0], unique[1])] if len(unique) == 2 else []
        for a, b in edges:
            if np.linalg.norm(b - a) > epsilon:
                segments.append([a.tolist(), b.tolist()])
                owners.append(int(index))
    return segments, owners, coplanar
