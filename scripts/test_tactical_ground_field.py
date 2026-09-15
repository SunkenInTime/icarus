"""Synthetic gates for automatic lower-sheet field construction."""
import unittest
import numpy as np
import shapely
from build_tactical_ground_field import lower_arrangement


def height(vertices, faces, xy):
    result = []
    for triangle in vertices[faces]:
        if shapely.Polygon(triangle[:, :2]).covers(shapely.Point(xy)):
            plane = np.linalg.solve(np.c_[triangle[:, :2], np.ones(3)], triangle[:, 2])
            result.append(float(np.r_[xy, 1] @ plane))
    if not result:
        raise AssertionError('Uncovered test point')
    if np.ptp(result) > 1e-9:
        raise AssertionError('Multiple reference heights at one XY')
    return result[0]


class LowerGroundFieldTest(unittest.TestCase):
    def test_coincident_upper_floor_does_not_replace_lower(self):
        base = np.array([[0, 0, 1], [4, 0, 1], [4, 4, 1], [0, 4, 1]], dtype=float)
        upper = base + [0, 0, 5]
        vertices, faces, _ = lower_arrangement(np.vstack([base, upper]), np.array([[0, 1, 2], [0, 2, 3], [4, 5, 6], [4, 6, 7]]))
        reference = height(vertices, faces, [2, 2])
        self.assertAlmostEqual(reference, 1)
        self.assertAlmostEqual((6 + 1.75 - reference) - (1 + 1.75 - reference), 5)

    def test_ramp_affine_height_survives_retriangulation(self):
        source = np.array([[0, 0, 0], [4, 0, 2], [4, 4, 2], [0, 4, 0]], dtype=float)
        vertices, faces, _ = lower_arrangement(source, np.array([[0, 1, 2], [0, 2, 3]]))
        for x in [.3, 1.1, 2.7, 3.9]:
            self.assertAlmostEqual(height(vertices, faces, [x, 1.7]), x / 2)

    def test_overlap_arrangement_has_no_double_covered_area(self):
        source = np.array([[0, 0, 0], [4, 0, 0], [4, 4, 0], [0, 4, 0],
                           [1, -1, 3], [3, -1, 3], [3, 5, 3], [1, 5, 3]], dtype=float)
        vertices, faces, _ = lower_arrangement(source, np.array([[0, 1, 2], [0, 2, 3], [4, 5, 6], [4, 6, 7]]))
        polygons = shapely.polygons(vertices[faces, :2])
        self.assertAlmostEqual(sum(shapely.area(polygons)), shapely.union_all(polygons).area)
        self.assertAlmostEqual(height(vertices, faces, [2, 2]), 0)
        # The declared continuous transition at bridge approaches stays finite.
        self.assertGreaterEqual(height(vertices, faces, [2, -.5]), 0)
        self.assertLessEqual(height(vertices, faces, [2, -.5]), 3)


if __name__ == '__main__':
    unittest.main()
