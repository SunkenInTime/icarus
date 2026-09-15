"""Explicit source objects represented by ink but excluded by broad name filters.

These declarations identify an obstacle. Local source facets still determine
its height; neither the whole object's bounding box nor its name supplies it.
"""
import numpy as np

REPRESENTED = {
    'ascent': {
        'p12-stroke-1': dict(
            object=6285,
            path='Ascent_Art_APathMid/TreeRoomTree_0/StaticMeshComponent0.145',
            role='Represented solid Tree-room trunk',
            material='Tree_2_M0_Trunk_MI',
            gameplaySource='https://dignitas.gg/articles/the-ultimate-killjoy-ascent-guide-for-valorant',
            image='https://cdn.sanity.io/images/ccckgjf9/production/c35caa812ee03ad8bd1df04f02ed0c3bd874ea00-1920x1080.png',
            evidence='The gameplay image shows the solid trunk occupying this '
                     'corner. Native mesh has one opaque trunk material section. '
                     'Horizontal source sections at 4.15, 5.7 and 9 m confirm '
                     'that this drawn corner encloses the trunk. Separate ivy '
                     'and canopy objects remain decorative.'),
    },
}


def represented_objects(name, metadata):
    rows = REPRESENTED.get(name, {})
    for row in rows.values():
        if metadata[row['object']]['path'] != row['path']:
            raise ValueError(('Represented source object identity changed', name, row))
    return rows


class RepresentedSourceRays:
    """Independent raw-triangle rays for explicitly represented solid objects."""

    def __init__(self, name, source, metadata):
        self.declarations = represented_objects(name, metadata)
        self.objects = []
        if not self.declarations:
            return
        with np.load(source / 'geometry.npz') as data:
            for row in self.declarations.values():
                obj = metadata[row['object']]
                ids = np.arange(obj['firstFace'], obj['firstFace'] + obj['faceCount'])
                triangles = data['points'][data['faces'][ids]].astype(float)
                self.objects.append((row, ids, triangles))

    def cast(self, origin, end):
        direction = end - origin
        length = np.linalg.norm(direction)
        direction /= length
        winner = None
        for row, ids, tri in self.objects:
            lower, upper = tri.min(axis=(0, 1)), tri.max(axis=(0, 1))
            if np.any(np.maximum(origin, end) < lower) or np.any(np.minimum(origin, end) > upper):
                continue
            e1, e2 = tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0]
            h = np.cross(direction, e2)
            det = np.sum(e1 * h, axis=1)
            inv = np.divide(1., det, out=np.zeros_like(det), where=abs(det) > 1e-12)
            s = origin - tri[:, 0]
            u = inv * np.sum(s * h, axis=1)
            q = np.cross(s, e1)
            v = inv * (q @ direction)
            distance = inv * np.sum(e2 * q, axis=1)
            take = ((abs(det) > 1e-12) & (u >= 0) & (v >= 0) & (u + v <= 1)
                    & (distance > 1e-7) & (distance <= length))
            hits = np.flatnonzero(take)
            if not len(hits):
                continue
            i = hits[distance[hits].argmin()]
            if winner is None or distance[i] < winner['distanceMeters']:
                winner = dict(distanceMeters=float(distance[i]), sourceFace=int(ids[i]),
                              sourceObject=row['object'], sourcePath=row['path'])
        return winner
