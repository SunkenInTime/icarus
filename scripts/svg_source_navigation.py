"""Local passage evidence from the extracted walkable navigation surface."""
import numpy as np
import shapely

from audit_all_map_gameplay_levels import planes
from build_all_map_gameplay_supports import navigation_triangles


class SourceNavigation:
    def __init__(self, name):
        self.triangles = navigation_triangles(name)
        self.shapes = shapely.polygons(self.triangles[:, :, :2])
        self.tree = shapely.STRtree(self.shapes)
        self.planes = planes(self.triangles)

    def heights(self, point):
        ids = self.tree.query(shapely.Point(point), predicate='intersects')
        return [(int(i), float(self.planes[i, :2] @ point + self.planes[i, 2])) for i in ids]

    def crossing(self, center, normal, expected_floor, half_length=2.):
        """Require a continuous local walk across the source plane on one level.

        Sampling is evidence for classifying a mark/passage, not a substitute
        for the complete wall-height and production-cone checks.
        """
        offsets = np.linspace(-half_length, half_length, 17)
        options = [self.heights(center + d * normal) for d in offsets]
        if any(not row for row in options):
            return None
        middle = len(options) // 2
        candidates = [(abs(z - expected_floor), i, z) for i, z in options[middle]
                      if abs(z - expected_floor) <= .5]
        for _, center_id, z in sorted(candidates):
            route = {middle: (center_id, z)}
            valid = True
            for sign in [-1, 1]:
                previous = z
                for step in range(1, middle + 1):
                    index = middle + sign * step
                    nearby = [(abs(height - previous), face, height) for face, height in options[index]
                              if abs(height - previous) <= 2 * half_length / 16 + .05]
                    if not nearby:
                        valid = False
                        break
                    _, face, height = min(nearby)
                    route[index] = (face, height)
                    previous = height
                if not valid:
                    break
            if valid:
                return dict(centerFloorMeters=z, halfLengthMeters=half_length,
                    triangleIds=[route[i][0] for i in range(len(offsets))],
                    positionsNative=[[*(center + d * normal), route[i][1]] for i, d in enumerate(offsets)])
        return None
