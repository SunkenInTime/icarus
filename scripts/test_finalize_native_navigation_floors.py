import unittest

import numpy as np

from finalize_native_navigation_floors import refine_changed_columns


class NativeFloorRefinementTest(unittest.TestCase):
    def test_added_and_removed_floor_recast_only_affected_native_columns(self):
        triangles = np.array([[[0, 0, 0], [2, 0, 0], [0, 2, 0]],
                              [[0, 0, .2], [2, 0, .2], [0, 2, .2]],
                              [[0, 0, 4], [2, 0, 4], [0, 2, 4]]], dtype=np.float32)
        nav = {'vertices': [20, -20, 10, 300, -300, 10]}
        baseline = {'refinedFloorHeightsCm': [0., 1.23456789],
                    'summary': {'medianNavLiftCm': 10.},
                    'checks': [{'vertex': 0, 'sourceZCm': 10., 'refinedZCm': 0.,
                                'accepted': True, 'materialCategory': 'opaque'},
                               {'vertex': 1, 'sourceZCm': 10., 'refinedZCm': 1.23456789,
                                'accepted': False, 'materialCategory': None}]}
        added, proof = refine_changed_columns(baseline, nav, triangles, [1, 2], [0, 1, 2])
        self.assertAlmostEqual(added['refinedFloorHeightsCm'][0], 20, places=5)
        self.assertEqual(added['refinedFloorHeightsCm'][1], 1.23456789)
        self.assertEqual([r['vertex'] for r in proof['checkedColumns']], [0])
        removed, proof = refine_changed_columns(added, nav, triangles, [1], [0, 2])
        self.assertEqual(removed['refinedFloorHeightsCm'][0], 0)
        self.assertEqual(removed['refinedFloorHeightsCm'][1], 1.23456789)


if __name__ == '__main__':
    unittest.main()
