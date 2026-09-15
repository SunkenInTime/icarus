import unittest
import numpy as np
from compile_complete_source_height_oracle import disjoint_control_cover, source_triangle_distances


class CompleteSourceOracleTests(unittest.TestCase):
    def test_partition_rejects_loss_duplication_and_outside_ids(self):
        disjoint_control_cover(4, [3, 0], [1, 2])
        for unchanged, removed in [([0], [1, 2]), ([0, 1], [1, 2]), ([0, 1], [2, 4])]:
            with self.assertRaises(ValueError):
                disjoint_control_cover(4, unchanged, removed)

    def test_face_plane_edge_and_vertex_distances(self):
        face = np.array([[[0., 0, 0], [2, 0, 0], [0, 2, 0]]])
        points = np.array([[[.5, .5, 3], [1, -2, 0], [3, 0, 0]]])
        np.testing.assert_allclose(source_triangle_distances(points, face), [[3, 2, 1]])
        np.testing.assert_allclose(source_triangle_distances(points, face[:, ::-1]), [[3, 2, 1]])

    def test_skinny_and_degenerate_faces_keep_metric_error(self):
        faces = np.array([[[0., 0, 0], [1, 0, 0], [0, 1e-12, 0]],
                          [[0., 0, 0], [1, 0, 0], [0, 0, 0]]])
        points = np.array([[[.5, -1e-9, 0], [.5, -1e-3, 0], [.25, 0, 0]]]*2)
        np.testing.assert_allclose(source_triangle_distances(points, faces), [[1e-9, 1e-3, 0]]*2, atol=1e-16)


if __name__ == '__main__':
    unittest.main()
