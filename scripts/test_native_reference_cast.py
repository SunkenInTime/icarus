import os
from pathlib import Path
import unittest
import numpy as np
from native_reference_cast import NativeReferenceModel
from test_audit_tactical_target_rays import scene, wall

LIBRARY = os.environ.get('ICARUS_REFERENCE_CAST_DLL')


@unittest.skipUnless(LIBRARY and Path(LIBRARY).is_file(), 'Build the diagnostic DLL and set ICARUS_REFERENCE_CAST_DLL')
class NativeCastTests(unittest.TestCase):
    def model(self, triangles):
        original = scene(triangles)
        result = NativeReferenceModel.__new__(NativeReferenceModel)
        result.arrays = {key: np.asarray(value, dtype='<u4' if key == 'faces' else '<i4' if key in ('nodes', 'faceMasks') else '<f8')
                         for key, value in original.arrays.items()}
        result.bind(LIBRARY)
        return result

    def test_internal_join_keeps_face_at_both_segment_ends(self):
        model = self.model(wall(5, 8))
        self.assertIsNone(model.cast([0, 0, 1.75], [5, 0, 1.75]))
        self.assertAlmostEqual(model.cast([0, 0, 1.75], [5, 0, 1.75], end_padding=0)['distanceMeters'], 5)
        self.assertAlmostEqual(model.cast([5, 0, 1.75], [10, 0, 1.75], min_distance=0)['distanceMeters'], 0)

    def test_nearest_face_wins_with_five_micrometre_separation(self):
        model = self.model(wall(5, 8) + wall(5 - 5e-6, 8))
        self.assertAlmostEqual(model.cast([0, 0, 1.75], [10, 0, 1.75])['distanceMeters'], 5 - 5e-6, places=9)

    def test_global_line_interval_keeps_submicrometre_piece_and_closed_join(self):
        model = self.model(wall(5, 8))
        for lo, hi in [(5-2e-7,5+2e-7),(0,5),(5,10)]:
            hit=model.cast([0,0,1.75],[10,0,1.75],min_distance=lo,end_padding=10-hi,end_inclusive=True)
            self.assertIsNotNone(hit)
            self.assertEqual(hit['distanceMeters'],5)

    def test_transparent_mask_does_not_hide_coincident_solid_face(self):
        model = self.model(wall(5, 8) + wall(5, 8))
        model.arrays['faceMasks'][:2] = [0, 1]
        model.arrays['maskedMaterials'] = np.array([0, 0])
        model.arrays['maskedUvs'] = np.zeros((2, 3, 2))
        model.materials = {0: dict(texture=0, wrapS='clamp', wrapT='clamp', threshold=.5)}
        model.textures = [np.zeros((1, 1))]
        result = model.cast([0, 0, 1.75], [10, 0, 1.75])
        self.assertGreaterEqual(result['face'], 2)
        self.assertAlmostEqual(result['distanceMeters'], 5)

    def test_solid_mask_blocks(self):
        model = self.model(wall(5, 8))
        model.arrays['faceMasks'][:] = [0, 1]
        model.arrays['maskedMaterials'] = np.array([0, 0])
        model.arrays['maskedUvs'] = np.zeros((2, 3, 2))
        model.materials = {0: dict(texture=0, wrapS='clamp', wrapT='clamp', threshold=.5)}
        model.textures = [np.ones((1, 1))]
        self.assertAlmostEqual(model.cast([0, 0, 1.75], [10, 0, 1.75])['distanceMeters'], 5)


if __name__ == '__main__':
    unittest.main()
