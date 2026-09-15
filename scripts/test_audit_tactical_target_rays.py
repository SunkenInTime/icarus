import unittest

import numpy as np

from audit_tactical_target_rays import ReferenceModel


def scene(triangles):
    vertices = np.asarray(triangles, dtype=float).reshape(-1, 3)
    count = len(vertices) // 3
    model = ReferenceModel.__new__(ReferenceModel)
    model.arrays = {
        'vertices': vertices,
        'faces': np.arange(len(vertices)).reshape(-1, 3),
        'bounds': np.r_[vertices.min(axis=0), vertices.max(axis=0)][None],
        'nodes': np.array([[0, count, -1, -1]]),
        'faceMasks': np.full(count, -1),
    }
    return model


def wall(x, height):
    return [[[x, -2, 0], [x, 2, 0], [x, 2, height]],
            [[x, -2, 0], [x, 2, height], [x, -2, height]]]


class TargetRayTest(unittest.TestCase):
    def test_slope_intersects_horizontal_but_not_eye_to_eye(self):
        model = scene([[[0, -2, 0], [10, -2, 4], [10, 2, 4]],
                       [[0, -2, 0], [10, 2, 4], [0, 2, 0]]])
        self.assertIsNotNone(model.cast([0, 0, 1.75], [10, 0, 1.75]))
        self.assertIsNone(model.cast([0, 0, 1.75], [10, 0, 5.75]))
        self.assertIsNone(model.cast([10, 0, 5.75], [0, 0, 1.75]))

    def test_full_wall_blocks_both(self):
        model = scene(wall(5, 8))
        for target in ([10, 0, 1.75], [10, 0, 5.75]):
            hit = model.cast([0, 0, 1.75], target)
            self.assertIsNotNone(hit)
            self.assertAlmostEqual(hit['point'][0], 5)

    def test_low_cover_can_block_downward_view_but_not_horizontal(self):
        model = scene(wall(5, 3))
        self.assertIsNone(model.cast([10, 0, 3.75], [0, 0, 3.75]))
        self.assertIsNotNone(model.cast([10, 0, 3.75], [0, 0, 1.75]))

    def test_wall_beyond_target_does_not_block(self):
        model = scene(wall(12, 8))
        self.assertIsNone(model.cast([0, 0, 1.75], [10, 0, 5.75]))

    def test_nearest_wall_wins_regardless_of_face_order(self):
        model = scene(wall(7, 8) + wall(3, 8))
        self.assertAlmostEqual(model.cast([0, 0, 1.75], [10, 0, 1.75])['distanceMeters'], 3)

    def test_wall_at_piecewise_join_is_not_lost(self):
        model = scene(wall(5, 8))
        self.assertIsNone(model.cast([0, 0, 1.75], [5, 0, 1.75]))
        hit = model.cast([0, 0, 1.75], [5, 0, 1.75], end_padding=0)
        self.assertAlmostEqual(hit['distanceMeters'], 5)
        hit = model.cast([5, 0, 1.75], [10, 0, 1.75], min_distance=0)
        self.assertAlmostEqual(hit['distanceMeters'], 0)

    def test_endpoint_padding_does_not_skip_a_nearer_wall(self):
        model = scene(wall(5, 8) + wall(5 - 5e-6, 8))
        hit = model.cast([0, 0, 1.75], [10, 0, 1.75])
        self.assertAlmostEqual(hit['distanceMeters'], 5 - 5e-6, places=9)


if __name__ == '__main__':
    unittest.main()
