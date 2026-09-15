import unittest
import numpy as np
from probe_unchanged_attachment_mapping import neighbor_pairs


class AttachmentMappingTest(unittest.TestCase):
    def test_finds_shared_attachment_with_reconstruction_rounding(self):
        moved = np.array([[1., 2., 3.], [4., 5., 6.]])
        retained = np.array([[4., 5., 6. + 1e-12], [1., 2., 3.]])
        np.testing.assert_array_equal(neighbor_pairs(moved, retained), [[1, 0], [0, 1]])

    def test_does_not_join_distinct_height_or_source_gap(self):
        moved = np.array([[1., 2., 3.]])
        retained = np.array([[1., 2., 3.1], [1.000001, 2., 3.]])
        self.assertEqual(neighbor_pairs(moved, retained).shape, (0, 2))


if __name__ == '__main__':
    unittest.main()
