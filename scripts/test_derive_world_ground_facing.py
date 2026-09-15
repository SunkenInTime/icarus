import unittest

import numpy as np

from derive_world_ground_facing import authored_facing_signs


class AuthoredGroundFacingTest(unittest.TestCase):
    def test_mirrored_triangle_and_import_reversal_have_same_authored_upward_side(self):
        local = np.array([[[0., 0., 0.], [100., 0., 0.], [0., 100., 0.]]])
        transform = np.diag([-1., 1., 1., 1.])
        actual = (local @ transform[:3, :3]) / 100
        signs, proof = authored_facing_signs(local, transform, actual)
        self.assertEqual(signs.tolist(), [-1])
        self.assertEqual((signs * proof['normal'][:, 2]).tolist(), [1])
        reordered = actual[:, [0, 2, 1]]
        signs, proof = authored_facing_signs(local, transform, reordered)
        self.assertEqual(signs.tolist(), [1])
        self.assertEqual((signs * proof['normal'][:, 2]).tolist(), [1])

    def test_nonuniform_shear_and_authored_handedness_are_respected(self):
        local = np.array([[[0., 0., 0.], [100., 0., 20.], [0., 100., 0.]]])
        transform = np.eye(4)
        transform[:3, :3] = [[-2, .1, .4], [0, 3, 0], [.2, 0, .5]]
        actual = (local @ transform[:3, :3]) / 100
        right, right_proof = authored_facing_signs(local, transform, actual)
        left, left_proof = authored_facing_signs(local, transform, actual, 'leftHanded')
        self.assertEqual(right.tolist(), [-1])
        self.assertEqual(left.tolist(), [1])
        self.assertAlmostEqual(right_proof['absoluteNormalDot'][0], 1)
        np.testing.assert_allclose(right_proof['authoredNormal'], -left_proof['authoredNormal'])

    def test_singular_transform_has_no_invented_authored_normal(self):
        local = np.array([[[0., 0., 0.], [100., 0., 0.], [0., 100., 0.]]])
        with self.assertRaisesRegex(ValueError, 'Singular'):
            authored_facing_signs(local, np.diag([1., 1., 0., 1.]), local)


if __name__ == '__main__':
    unittest.main()
