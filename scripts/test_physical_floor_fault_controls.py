import unittest

import numpy as np

from verify_physical_floor_fault_controls import matching_ground_triangles


class FloorFaultTests(unittest.TestCase):
    def test_sloped_floor_matches_at_pose_and_separate_level_survives(self):
        ramp = np.array([[0., 0., 1.], [10., 0., 4.], [0., 10., 1.]])
        upper = ramp + [0., 0., 2.]
        vertices = np.concatenate([ramp, upper])
        triangles = np.array([[0, 1, 2], [3, 4, 5]])
        self.assertEqual(matching_ground_triangles(vertices, triangles, [5., 2.], 2.5), {0})
        self.assertEqual(matching_ground_triangles(vertices, triangles, [5., 2.], 4.5), {1})
        # None of the ramp's corner heights is near the height at the pose.
        self.assertTrue(np.all(abs(ramp[:, 2]-2.5) > .02))

    def test_flat_and_degenerate_triangles(self):
        vertices = np.array([[0., 0., 3.], [10., 0., 3.], [0., 10., 3.]])
        triangles = np.array([[0, 1, 2], [0, 1, 1]])
        self.assertEqual(matching_ground_triangles(vertices, triangles, [2., 2.], 3.), {0})
        self.assertEqual(matching_ground_triangles(vertices, triangles, [2., 2.], 3.1), set())


if __name__ == '__main__':
    unittest.main()
