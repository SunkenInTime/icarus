import unittest

import numpy as np

from lift_reviewed_wall_source_heights import area, triangle_barycentrics, map_discarded_region


class SourceHeightBridgeTests(unittest.TestCase):
    def test_vertical_oblique_source_keeps_height_and_triangle_coordinates(self):
        source = np.array([[[2., 3., 7.], [6., 5., 7.], [6., 5., 13.]]])
        expected = np.array([[[.2, .3, .5], [.1, .8, .1], [.6, .1, .3]]])
        points = expected @ source
        recovered, error = triangle_barycentrics(points, source)
        np.testing.assert_allclose(recovered, expected, atol=1e-14, rtol=0)
        self.assertLess(error, 1e-13)

    def test_wrong_ground_recovery_is_detected_on_sloping_source(self):
        source = np.array([[[0., 0., 2.], [2., 0., 3.], [0., 2., 4.]]])
        points = source.copy()
        points[:, :, 2] += .01
        _, error = triangle_barycentrics(points, source)
        self.assertGreater(error, .001)

    def test_relative_zero_area_can_hide_source_world_wall_area(self):
        # A triangular sloped surface is flat after subtracting ground. Its
        # along/Z projection gains area when original height is restored.
        relative = np.array([[[0., 0.], [2., 0.], [1., 0.]]])
        original = np.array([[[0., 0.], [2., 0.], [1., 1.]]])
        self.assertEqual(area(relative)[0], 0)
        self.assertEqual(area(original)[0], 1)

    def test_region_collapse_retains_absolute_height_area(self):
        family = dict(sourceVerticesSvg=[[0,0],[4,0],[0,4]],
                      targetVerticesSvg=[[10,20],[14,20],[10,20]], triangles=[[0,1,2]])
        control = np.array([[[0.,0.,0.],[2.,0.,0.],[1.,1.,0.]]])
        mapped, cells, proof = map_discarded_region(family, control, np.eye(3)[None],
            np.array([0]), np.eye(2), np.zeros(2), np.array([17]), {})
        np.testing.assert_allclose(mapped, [[[10,20],[12,20],[11,20]]], rtol=0, atol=0)
        # Restoring the original sloped height recovers a nonempty vertical
        # wall even though the provisional relative-height piece was flat.
        absolute = np.dstack((mapped, np.array([[2.,2.,3.]])))
        self.assertGreater(np.linalg.norm(np.cross(absolute[0,1]-absolute[0,0],
            absolute[0,2]-absolute[0,0])), 0)
        self.assertEqual(cells.tolist(), [0])

    def test_prepartition_discard_requires_a_real_containing_cell(self):
        family = dict(sourceVerticesSvg=[[0,0],[4,0],[0,4]],
                      targetVerticesSvg=[[10,20],[14,20],[10,24]], triangles=[[0,1,2]])
        inside = np.array([[[1.,1.,0.],[1.,1.,1.],[2.,1.,1.]]])
        _, cells, _ = map_discarded_region(family, inside, np.eye(3)[None],
            np.array([-1]), np.eye(2), np.zeros(2), np.array([18]), {})
        self.assertEqual(cells.tolist(), [0])
        outside = inside.copy(); outside[0,2,0] = 3.01
        with self.assertRaises(ValueError):
            map_discarded_region(family, outside, np.eye(3)[None], np.array([-1]),
                np.eye(2), np.zeros(2), np.array([18]), {})


if __name__ == '__main__':
    unittest.main()
