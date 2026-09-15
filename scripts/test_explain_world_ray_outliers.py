import unittest

import numpy as np

from explain_world_ray_outliers import intersection


class SourceTriangleDiagnosticTests(unittest.TestCase):
    def test_exact_top_edge_and_micrometre_height_sides(self):
        triangle = np.array([[2., -1., 0.], [2., 1., 1.], [2., -1., 1.]])
        direction = np.array([1., 0., 0.])
        for elevation, expected in ((1., True), (1. - 1e-6, True), (1. + 1e-6, False)):
            result = intersection(triangle, np.array([0., 0., elevation]), direction)
            self.assertEqual(result['closedHitWithinNumericTolerance'], expected)
            self.assertAlmostEqual(result['distanceMeters'], 2.)

    def test_parallel_degenerate_and_behind_origin_do_not_become_hits(self):
        triangle = np.array([[2., -1., 0.], [2., 1., 1.], [2., -1., 1.]])
        self.assertTrue(intersection(triangle, np.zeros(3), np.array([0., 1., 0.]))['parallelOrDegenerate'])
        self.assertTrue(intersection(np.zeros((3, 3)), np.zeros(3), np.array([1., 0., 0.]))['parallelOrDegenerate'])
        self.assertFalse(intersection(triangle, np.array([3., 0., .75]), np.array([1., 0., 0.]))['closedHitWithinNumericTolerance'])


if __name__ == '__main__':
    unittest.main()
