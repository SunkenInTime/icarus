import unittest
import numpy as np
from scipy.spatial.transform import Rotation

from native_instance_collision import compose_physics, decompose


class NativeInstanceTests(unittest.TestCase):
    def test_native_normalization_preserves_serialized_rotation(self):
        matrix = np.eye(4)
        matrix[:3, :3] = np.diag([2., 3., 4.]) @ Rotation.from_euler('xyz', [7, 89, 170], degrees=True).as_matrix().T
        scale, rotation, _ = decompose(matrix)
        np.testing.assert_allclose(scale[:, None] * rotation, matrix[:3, :3], atol=1e-12)
        np.testing.assert_allclose(rotation @ rotation.T, np.eye(3), atol=1e-12)

    def test_physics_composition_does_not_shear_instance_with_parent_scale(self):
        instance = np.array([[0., 2., 0., 0.], [-3., 0., 0., 0.], [0., 0., 4., 0.], [10., 20., 30., 1.]])
        parent = np.diag([3., 5., 2., 1.])
        parent[3, :3] = [1., 2., 3.]
        result = compose_physics(instance, parent)
        np.testing.assert_allclose(result[:3, :3], [[0, 6, 0], [-15, 0, 0], [0, 0, 8]], atol=1e-12)
        np.testing.assert_allclose(result[3, :3], [31, 102, 63])
        self.assertFalse(np.allclose(result, instance @ parent))

    def test_reflected_parent_preserves_native_body_placement(self):
        instance = np.eye(4)
        instance[:3, :3] = np.diag([2., 3., 4.]) @ Rotation.from_euler('xyz', [7, 89, 170], degrees=True).as_matrix().T
        parent = np.diag([-1., 1., 1., 1.])
        np.testing.assert_allclose(compose_physics(instance, parent), instance @ parent, atol=1e-12)


if __name__ == '__main__':
    unittest.main()
