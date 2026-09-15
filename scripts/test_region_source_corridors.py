import unittest
import numpy as np

from probe_region_source_corridors import conservative_hits


class SourceCorridorTest(unittest.TestCase):
    def test_wall_blocks_at_original_height(self):
        wall = np.array([[[0.,-1,5], [0,1,5], [0,0,9]]])
        hits, unresolved = conservative_hits(wall, np.array([-1.,0,6]), np.array([1.,0,6]))
        self.assertEqual(len(hits), 1)
        self.assertFalse(unresolved)

    def test_upper_wall_keeps_lower_corridor_clear(self):
        wall = np.array([[[0.,-1,9], [0,1,9], [0,0,12]]])
        hits, unresolved = conservative_hits(wall, np.array([-1.,0,6]), np.array([1.,0,6]))
        self.assertFalse(hits)
        self.assertFalse(unresolved)

    def test_coplanar_intersection_cannot_be_certified_clear(self):
        floor = np.array([[[-2.,-2,6], [2,-2,6], [0,2,6]]])
        hits, unresolved = conservative_hits(floor, np.array([-1.,0,6]), np.array([1.,0,6]))
        self.assertFalse(hits)
        self.assertEqual(unresolved, [0])

    def test_wall_past_target_does_not_block_finite_corridor(self):
        wall = np.array([[[2.,-1,5], [2,1,5], [2,0,9]]])
        hits, unresolved = conservative_hits(wall, np.array([-1.,0,6]), np.array([1.,0,6]))
        self.assertFalse(hits)
        self.assertFalse(unresolved)


if __name__ == '__main__':
    unittest.main()
