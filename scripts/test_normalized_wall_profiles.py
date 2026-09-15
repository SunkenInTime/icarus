"""A matching area sum must not conceal overlapping and missing source data."""
import unittest
from unittest.mock import patch
import numpy as np
import shapely
from verify_normalized_wall_profiles import verify_source_partition, profile_frame, reconstruct_source_points


class SourcePartitionTest(unittest.TestCase):
    def test_geos_exception_uses_exact_proof_and_still_rejects_overlap(self):
        bary = np.eye(3)[None]
        with patch('verify_normalized_wall_profiles.shapely.union_all',
                   side_effect=shapely.errors.GEOSException('numeric union failure')):
            report = verify_source_partition(np.array([7]), bary, [7])
            self.assertEqual(report['maximumRelativeCoverageError'], 0.)
            self.assertEqual(report['exactRationalFallbacks'][0]['geosException'], 'numeric union failure')
            with self.assertRaises(AssertionError):
                verify_source_partition(np.array([7, 7]), np.concatenate((bary, bary)), [7])

    def test_interpolation_preserves_constant_plane_at_large_offset(self):
        # A mounted wall may have tiny cells far from the origin. Repeatedly
        # weighting its absolute plane coordinate can shift a cell boundary.
        tri = np.array([[[1048576., 20., 7.], [1048576., 22., 8.],
                         [1048576., 21., 9.]]])
        uv = np.array([[[.13, .27], [.72, .14], [.31, .48]]])
        weights = np.concatenate((1 - uv.sum(axis=2, keepdims=True), uv), axis=2)
        actual = reconstruct_source_points(weights, tri)
        np.testing.assert_array_equal(actual[:, :, 0], np.full((1, 3), 1048576.))
        shifted = tri.copy()
        shifted[:, :, 0] -= 1048576.
        np.testing.assert_array_equal(actual[:, :, 1:], reconstruct_source_points(weights, shifted)[:, :, 1:])
        np.testing.assert_allclose(actual[:, :, 2], 7 + uv[:, :, 0] + 2 * uv[:, :, 1], atol=2e-15, rtol=0)

    def test_interpolation_retains_vertices_and_outside_position(self):
        tri = np.array([[[100., 200., 3.], [104., 201., 5.], [104., 201.00001, 7.]]])
        np.testing.assert_array_equal(reconstruct_source_points(np.eye(3)[None], tri), tri)
        weights = np.array([[[-.25, .5, .75]]])
        np.testing.assert_allclose(reconstruct_source_points(weights, tri),
                                   [[[105., 201.2500075, 7.]]], atol=3e-14, rtol=0)

    def test_partition_covers_original_once(self):
        a, b, c = np.eye(3)
        mid = (b + c) / 2
        result = verify_source_partition(np.array([7, 7]), np.array([[a, b, mid], [a, mid, c]]), [7])
        self.assertEqual(result['maximumRelativeCoverageError'], 0.)

    def test_equal_area_overlap_and_hole_rejected(self):
        a, b, c = np.eye(3)
        half = np.array([a, b, (b + c) / 2])
        self.assertAlmostEqual(2 * abs(np.linalg.det(half)), 1.)
        with self.assertRaises(AssertionError):
            verify_source_partition(np.array([7, 7]), np.array([half, half]), [7])

    def test_rotated_frame_preserves_along_and_normal_coordinates(self):
        theta = .37
        tangent = np.array([np.cos(theta), np.sin(theta)])
        normal = np.array([-tangent[1], tangent[0]])
        origin = np.array([5., -2.])
        family = dict(sourceFrame=dict(origin=[0, 0], tangent=[1, 0], normal=[0, 1]),
                      targetFrame=dict(origin=origin, tangent=tangent, normal=normal))
        o, t, n = profile_frame(family, 'target')
        point = origin + 3 * tangent - 2 * normal
        self.assertAlmostEqual(float((point - o) @ t), 3.)
        self.assertAlmostEqual(float((point - o) @ n), -2.)
        family['targetFrame']['normal'] = -normal
        with self.assertRaises(AssertionError):
            profile_frame(family, 'target')


if __name__ == '__main__':
    unittest.main()
