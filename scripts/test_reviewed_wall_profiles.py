"""Wall distillation must retain a window rather than union maximum heights."""
import unittest
import numpy as np
import shapely
from compile_reviewed_wall_profiles import union_profiles


class WallProfileTest(unittest.TestCase):
    def test_window_and_low_wall_remain_open_above_their_profiles(self):
        triangles = []
        for x0, z0, x1, z1 in [(0, 0, 1, 4), (3, 0, 4, 4), (1, 0, 3, 1), (1, 3, 3, 4), (4, 0, 6, 1)]:
            triangles.extend([[[x0, z0], [x1, z0], [x1, z1]], [[x0, z0], [x1, z1], [x0, z1]]])
        result = union_profiles(np.array(triangles, float))
        self.assertTrue(result.covers(shapely.Point(.5, 2)))
        self.assertFalse(result.covers(shapely.Point(2, 2)))
        self.assertTrue(result.covers(shapely.Point(2, 3.5)))
        self.assertFalse(result.covers(shapely.Point(5, 2)))
        self.assertTrue(result.covers(shapely.Point(5, .5)))


if __name__ == '__main__':
    unittest.main()
