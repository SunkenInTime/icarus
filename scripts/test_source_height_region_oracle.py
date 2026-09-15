import unittest
import numpy as np

from compile_reviewed_source_world_oracle import restore_triangle
from tactical_alignment_composite import explicit_warp
from verify_normalized_wall_profiles import verify_source_partition


class SourceHeightRegionOracleTests(unittest.TestCase):
    def warp(self):
        points = np.array([[0.,0.],[4.,0.],[4.,4.],[0.,4.]])
        displacement = np.array([[0.,0.],[.2,0.],[.2,.1],[0.,0.]])
        return explicit_warp(points, displacement, np.array([[0,1,2],[0,2,3]]))

    def test_crossing_display_cells_preserves_height_and_source_coverage(self):
        triangle = np.array([[.5,1.,2.],[3.5,.5,3.],[2.5,3.5,5.]])
        warp = self.warp()
        restored = restore_triangle(triangle, warp, np.eye(2), np.zeros(2))
        self.assertGreater(len(restored), 1)
        weights = np.array([row[1] for row in restored])
        verify_source_partition(np.zeros(len(weights), dtype=int), weights, np.array([0]))
        for xyz, bary, cell in restored:
            np.testing.assert_allclose(xyz[:,2], bary @ triangle[:,2], rtol=0, atol=2e-15)
            np.testing.assert_allclose(xyz[:,:2], warp.apply(bary @ triangle[:,:2]), rtol=0, atol=2e-14)

    def test_collapsed_geometry_still_retains_source_partition(self):
        triangle = np.array([[1.,1.,2.],[1.,1.,2.],[1.,1.,2.]])
        restored = restore_triangle(triangle, self.warp(), np.eye(2), np.zeros(2))
        self.assertGreater(len(restored), 0)
        weights = np.array([row[1] for row in restored])
        verify_source_partition(np.zeros(len(weights), dtype=int), weights, np.array([0]))
        for xyz, _, _ in restored:
            np.testing.assert_allclose(xyz, np.repeat(xyz[:1], 3, axis=0), rtol=0, atol=0)


if __name__ == '__main__':
    unittest.main()
