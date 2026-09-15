"""Positive and deliberately shifted-wall controls for the region checker."""
import os
from pathlib import Path
import unittest
import numpy as np
from audit_wall_contact_pixels import PhysicalGeometry
from native_reference_cast import NativeReferenceModel
from test_audit_tactical_target_rays import scene, wall


LIBRARY = os.environ.get('ICARUS_REFERENCE_CAST_DLL')


@unittest.skipUnless(LIBRARY and Path(LIBRARY).is_file(), 'Set ICARUS_REFERENCE_CAST_DLL')
class ConeRegionGridTest(unittest.TestCase):
    def test_aligned_wall_and_early_or_late_shadow_controls(self):
        original = scene(wall(5, 8))
        model = NativeReferenceModel.__new__(NativeReferenceModel)
        model.arrays = {key: np.asarray(value, dtype='<u4' if key == 'faces'
            else '<i4' if key in ('nodes', 'faceMasks') else '<f8')
            for key, value in original.arrays.items()}
        model.bind(LIBRARY)
        warp = dict(targetAttackSvg=[-20., -20., 20., -20., 20., 20., -20., 20.],
            sourceNativeMeters=[-20., -20., 20., -20., 20., 20., -20., 20.],
            triangles=[0, 1, 2, 0, 2, 3], attackToDefenseSvg=dict(origin=[0., 0.]))
        row = dict(side='attack', query=[0., 0., 1.75, 1., 0., 15., np.pi/2])
        points = np.array([[4.9, 0.], [5.1, 0.]])
        expected = [model.cast([0., 0., 1.75], [x, y, 1.75]) is None for x, y in points]
        self.assertEqual(expected, [True, False])
        for wall_x, wanted in [(5., [True, False]), (4.8, [False, False]), (5.2, [True, True])]:
            shadow = np.array([[[wall_x, -20.], [20., -20.], [20., 20.]],
                               [[wall_x, -20.], [20., 20.], [wall_x, 20.]]])
            geometry = PhysicalGeometry(warp, row, shadow)
            actual = geometry.clear(points).tolist()
            self.assertEqual(actual, wanted)
            self.assertEqual(actual == expected, wall_x == 5.)


if __name__ == '__main__':
    unittest.main()
