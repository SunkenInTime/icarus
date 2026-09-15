import unittest
import numpy as np
from probe_shared_source_vertex_mapping import cross_family_pairs


class SharedSourceVertexMappingTest(unittest.TestCase):
    def test_separates_mapping_gap_from_source_rounding(self):
        source = np.array([[1., 2., 3.], [1.+1e-12, 2., 3.], [1., 2., 3.1]])
        target = np.array([[10., 20.], [11., 20.], [10., 20.]])
        pairs, source_gaps, target_gaps = cross_family_pairs(source, target, np.array([84, 85, 85]))
        np.testing.assert_array_equal(pairs, [[0, 1]])
        self.assertLess(source_gaps[0], 1e-9)
        self.assertEqual(target_gaps[0], 1.)

    def test_ignores_duplicate_records_within_one_family(self):
        pairs, _, _ = cross_family_pairs(np.zeros((3, 3)), np.zeros((3, 2)), np.array([84, 84, 84]))
        self.assertEqual(len(pairs), 0)


if __name__ == '__main__':
    unittest.main()
