"""Differential controls for the experimental floor sector edge selection."""
import math
import unittest
import numpy as np
from probe_floor_sector_index import SectorIndex


class FloorSectorIndexTest(unittest.TestCase):
    def compare(self, polygon, origin):
        index = SectorIndex(polygon, origin)
        angles = list(np.linspace(-math.pi, math.pi, 361))
        for point in polygon:
            angle = math.atan2(point[1]-origin[1], point[0]-origin[0])
            angles.extend(angle+d for d in [0., -1e-13, 1e-13, -1e-9, 1e-9])
        for angle in angles:
            for distance in [.01, 1., 100.]:
                direction = np.array([math.cos(angle), math.sin(angle)]) * distance
                expected = index.clip(direction)[0]
                actual = index.clip(direction, True)[0]
                self.assertEqual(expected, actual, (origin, angle, distance))

    def test_inside_outside_wrap_and_winding(self):
        angles = np.arange(35) * 2 * math.pi / 35
        polygon = np.column_stack([np.cos(angles), np.sin(angles)])
        for winding in [polygon, polygon[::-1]]:
            for origin in [[0., 0.], [2., 0.], [-2., 0.], [0., 2.], [1., 0.]]:
                self.compare(winding, origin)

    def test_thin_footprint_and_translated_coordinates(self):
        angles = np.arange(35) * 2 * math.pi / 35
        polygon = np.column_stack([np.cos(angles), np.sin(angles)*1e-6])
        for shift in [np.array([0., 0.]), np.array([500., -300.])]:
            for origin in [[0., 2e-6], [2., 0.], [0., 0.]]:
                self.compare(polygon+shift, np.array(origin)+shift)

    def test_exact_vertex_uses_full_clip(self):
        angles = np.arange(35) * 2 * math.pi / 35
        polygon = np.column_stack([np.cos(angles), np.sin(angles)])
        index = SectorIndex(polygon, [2., 0.])
        for vertex in polygon:
            self.assertFalse(index.clip(vertex-index.origin, True)[1])


if __name__ == '__main__':
    unittest.main()
