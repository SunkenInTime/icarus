import unittest

import numpy as np

from verify_restored_source_xy import affine_display, anchored, line_mapping, verify_displayed_xy


class RestoredXYTests(unittest.TestCase):
    def setUp(self):
        self.source = np.array([[[0., 0.], [1., 0.], [0., 1.]],
                                [[1., 0.], [1., 1.], [0., 1.]]])
        self.target = self.source.copy()
        self.target[1, 1] = [1.4, 1.2]

    def test_affine_triangle_and_shared_edge_and_point(self):
        triangles = np.array([[[.1, .1], [.8, .1], [.1, .8]],
                              [[0., 1.], [.5, .5], [1., 0.]],
                              [[.5, .5], [.5, .5], [.5, .5]]])
        actual, _, _ = affine_display(triangles, self.source, self.target)
        np.testing.assert_allclose(actual, triangles, atol=1e-15)

    def test_cross_cell_triangle_is_rejected_even_if_vertex_checks_pass(self):
        triangle = np.array([[[.1, .1], [.9, .3], [.3, .9]]])
        # Each vertex can be mapped correctly in isolation. That does not prove
        # their connecting edges or interior follow the same affine map.
        for point in triangle[0]:
            affine_display(np.repeat(point[None, None], 3, axis=1), self.source, self.target)
        with self.assertRaisesRegex(AssertionError, 'crosses W cells'):
            affine_display(triangle, self.source, self.target)

    def test_outside_triangle_rejected(self):
        with self.assertRaisesRegex(AssertionError, 'crosses W cells'):
            affine_display(np.array([[[2., 2.]]*3]), self.source, self.target)

    def test_tampered_restored_position_rejected(self):
        triangle = np.array([[[.1, .1], [.8, .1], [.1, .8]]])
        verify_displayed_xy(triangle, triangle, self.source, self.target)
        wrong = triangle.copy()
        wrong[0, 0, 0] += .01
        with self.assertRaisesRegex(AssertionError, 'authored XY mismatch'):
            verify_displayed_xy(wrong, triangle, self.source, self.target)

    def test_local_interpolation_retains_constant_coordinate(self):
        triangle = np.array([[[1000., 7.], [1001., 7.], [1000., 7.]]])
        bary = np.array([[[.1, .2, .7], [.2, .1, .7], [.3, .5, .2]]])
        np.testing.assert_array_equal(anchored(bary, triangle)[..., 1], 7.)

    def test_unsplit_clamp_rejected(self):
        family = dict(edge=1, axis=0, fixed=2., sourceAlong=[0., 1.], targetAlong=[0., 2.])
        points = np.array([[[-.1, 2.], [.3, 2.], [.1, 2.]]])
        with self.assertRaisesRegex(AssertionError, 'Unsplit source clamp'):
            line_mapping(family, points)


if __name__ == '__main__':
    unittest.main()
