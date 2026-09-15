"""A source edge or vertex at eye height must not certify empty transit."""
import unittest

import numpy as np

from probe_static_floor_sections import cast_segments, sections


def triangle_hit(start, end, triangle):
    # Independent line/triangle barycentric solve, including boundary points.
    direction = end - start
    a, b, c = triangle
    coefficients = np.column_stack((direction, a - b, a - c))
    if np.linalg.det(coefficients) == 0:
        return None
    t, u, v = np.linalg.solve(coefficients, a - start)
    return float(t) if 0 < t < 1 and u >= 0 and v >= 0 and u + v <= 1 else None


class FloorSectionContactTests(unittest.TestCase):
    patch = np.array([[-1., -1.], [1., -1.], [1., 1.], [-1., 1.]])
    plane = np.zeros(3)

    def extract(self, triangle, patch=None):
        result = sections(np.array([triangle]), np.array([71]), self.plane,
                          self.patch if patch is None else patch)
        self.assertIsNotNone(result)
        segments, faces = result
        self.assertEqual(faces, [71])
        return segments

    def test_top_and_bottom_edges_match_transverse_triangle_hit(self):
        start, end = np.array([-1., 0., 1.75]), np.array([1., 0., 1.75])
        for third_z in (0., 3.):
            triangle = np.array([[0., -1., 1.75], [0., 1., 1.75], [0., 0., third_z]])
            for winding in (triangle, triangle[::-1]):
                for patch in (self.patch, self.patch[::-1]):
                    segments = self.extract(winding, patch)
                    self.assertAlmostEqual(triangle_hit(start, end, winding), .5)
                    self.assertAlmostEqual(cast_segments(start[:2], end[:2], segments), .5)
                    np.testing.assert_allclose(np.sort(segments[0, :, 1]), [-1., 1.])

    def test_isolated_vertex_is_preserved_above_and_below_plane(self):
        start, end = np.array([-1., 0., 1.75]), np.array([1., 0., 1.75])
        for other_z in (0., 3.):
            triangle = np.array([[0., 0., 1.75], [0., -1., other_z], [0., 1., other_z]])
            segments = self.extract(triangle)
            np.testing.assert_array_equal(segments, np.zeros((1, 2, 2)))
            self.assertAlmostEqual(triangle_hit(start, end, triangle), .5)
            self.assertAlmostEqual(cast_segments(start[:2], end[:2], segments), .5)
            self.assertIsNone(cast_segments(np.array([-1., .01]), np.array([1., .01]), segments))

    def test_patch_corner_contact_is_not_dropped(self):
        triangle = np.array([[0., 2., 1.75], [2., 0., 1.75], [1., 1., 0.]])
        segments = self.extract(triangle)
        np.testing.assert_allclose(segments, np.ones((1, 2, 2)))

    def test_short_positive_section_is_not_rounded_away(self):
        triangle = np.array([[0., -1e-13, 1.75], [0., 1e-13, 1.75], [0., 0., 0.]])
        segments = self.extract(triangle)
        self.assertGreater(np.linalg.norm(segments[0, 1] - segments[0, 0]), 0)
        self.assertAlmostEqual(cast_segments(np.array([-1., 0.]), np.array([1., 0.]), segments), .5)


if __name__ == '__main__':
    unittest.main()
