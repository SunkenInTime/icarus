import unittest
import numpy as np

from horizontal_mesh_slice import slice_triangles


class HorizontalSliceTests(unittest.TestCase):
    def test_wall_crossing_retains_exact_height_intersections(self):
        segments, owners, coplanar = slice_triangles([[[2, 0, 0], [2, 4, 0], [2, 0, 4]]], 1)
        self.assertEqual(owners, [0])
        self.assertEqual(coplanar, 0)
        np.testing.assert_allclose(sorted(segments[0]), [[2, 0], [2, 3]])

    def test_low_cover_and_vertex_touch_have_no_length(self):
        triangle = [[[0, 0, 0], [1, 0, 0], [0, 1, 1]]]
        for height in [1, 1.75]:
            self.assertEqual(slice_triangles(triangle, height)[0], [])

    def test_plane_edge_is_retained_and_coplanar_faces_are_counted(self):
        triangle = [[[0, 0, 0], [1, 0, 0], [0, 1, 1]]]
        self.assertEqual(slice_triangles(triangle, 0)[0], [[[0.0, 0.0], [1.0, 0.0]]])
        flat = [[[0, 0, 0], [1, 0, 0], [0, 1, 0]]]
        segments, _, coplanar = slice_triangles(flat, 0)
        self.assertEqual(len(segments), 3)
        self.assertEqual(coplanar, 1)


if __name__ == '__main__':
    unittest.main()
