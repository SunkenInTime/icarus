import unittest
import numpy as np
from finite_edge_owners import edge_owners, clear_cache, cache_info, MAX_ENTRIES


class OwnershipCacheTests(unittest.TestCase):
    def setUp(self):
        clear_cache()
        self.cells = np.array([[0, 1, 2], [0, 2, 3]])

    def test_equal_topology_reuses_immutable_table(self):
        first = edge_owners(self.cells)
        self.assertIs(first, edge_owners(self.cells.copy()))
        with self.assertRaises(TypeError):
            first[(0, 2)] = 7
        self.assertEqual(first[(0, 2)], 0)

    def test_mutated_same_array_cannot_reuse_stale_owner(self):
        first = edge_owners(self.cells)
        self.cells[0] = [5, 6, 7]
        second = edge_owners(self.cells)
        self.assertIsNot(first, second)
        self.assertEqual(first[(0, 2)], 0)
        self.assertEqual(second[(0, 2)], 1)

    def test_reordered_faces_and_winding_keep_literal_first_owner(self):
        rows = np.array([[0, 1, 2], [1, 0, 3], [2, 1, 4]])
        for data in [rows, rows[::-1], rows[:, ::-1], rows.astype(np.int32)]:
            owners = edge_owners(data)
            for edge, first in owners.items():
                self.assertEqual(first, min(i for i, tri in enumerate(data) if all(v in tri for v in edge)))

    def test_bounded_eviction_cannot_confuse_different_topologies(self):
        first = edge_owners(self.cells)
        for i in range(MAX_ENTRIES+2):
            edge_owners(self.cells + 10*(i+1))
        info = cache_info()
        self.assertLessEqual(info['entries'], info['maximumEntries'])
        self.assertLessEqual(info['retainedPayloadUpperBoundBytes'], info['maximumPayloadBytes'])
        self.assertIsNot(first, edge_owners(self.cells))
        self.assertEqual(dict(first), dict(edge_owners(self.cells)))


if __name__ == '__main__':
    unittest.main()
