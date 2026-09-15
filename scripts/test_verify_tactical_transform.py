import unittest
import numpy as np
import shapely
from test_audit_tactical_target_rays import scene, wall
from verify_tactical_transform import source_cast


class SplitField:
    def __init__(self):
        self.polygons = np.array([shapely.box(0, -3, 5, 3), shapely.box(5, -3, 10, 3)])
        self.tree = shapely.STRtree(self.polygons)
        self.planes = np.zeros((2, 3))

    def locate(self, xy):
        return (xy[:, 0] > 5).astype(int)


class PiecewiseEndpointTest(unittest.TestCase):
    def test_internal_join_keeps_wall(self):
        hit = source_cast(scene(wall(5, 8)), SplitField(), np.array([0, 0, 1.75]), np.array([10, 0, 1.75]))
        self.assertIsNotNone(hit)
        self.assertAlmostEqual(hit['sourceRayParameter'], .5)

    def test_outer_endpoint_remains_excluded(self):
        hit = source_cast(scene(wall(10, 8)), SplitField(), np.array([0, 0, 1.75]), np.array([10, 0, 1.75]))
        self.assertIsNone(hit)

    def test_wall_just_after_join_is_kept(self):
        hit = source_cast(scene(wall(5 + 1e-7, 8)), SplitField(), np.array([0, 0, 1.75]), np.array([10, 0, 1.75]))
        self.assertAlmostEqual(hit['sourceRayParameter'], .5 + 1e-8)


if __name__ == '__main__':
    unittest.main()
