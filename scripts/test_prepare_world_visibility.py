import copy
import unittest
import numpy as np
from prepare_world_visibility import median_leaf_order, prepare


class OfflineBVHOrderTests(unittest.TestCase):
    def test_spatial_partition_is_complete_and_separates_clusters(self):
        rng = np.random.default_rng(834)
        segments = rng.uniform(-1, 1, (200, 2, 2))
        segments[:100, :, 0] -= 20
        segments[100:, :, 0] += 20
        order = median_leaf_order(segments)
        self.assertEqual(sorted(order), list(range(200)))
        self.assertEqual(set(order[:100]), set(range(100)))
        self.assertEqual(set(order[100:]), set(range(100, 200)))

    def test_preparation_changes_only_layer_order_and_keeps_shared_tables(self):
        data = {'coordinateScale': 1, 'uvUnitsPerMeter': [1, 2],
                'vertices': [0, 0, 1, 0, 10, 10, 11, 10],
                'edges': [0, 1, 2, 3],
                'layers': [{'elevationCm': 175, 'globalOrigins': True, 'edges': [1, 0]}]}
        original = copy.deepcopy(data)
        actual = prepare(data)
        self.assertEqual(actual['vertices'], original['vertices'])
        self.assertEqual(actual['edges'], original['edges'])
        self.assertEqual(set(actual['layers'][0]['edges']), set(original['layers'][0]['edges']))
        self.assertIs(prepare(actual), actual)


if __name__ == '__main__':
    unittest.main()
