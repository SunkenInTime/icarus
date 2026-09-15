import copy
import unittest

import numpy as np

from order_world_visibility_tables import order_tables, spatial_order


class SpatialTableOrderTests(unittest.TestCase):
    def test_ordered_directed_segments_and_metadata_survive_table_remapping(self):
        rng = np.random.default_rng(56)
        vertices = rng.integers(-1000000, 1000000, (500, 2))
        edges = rng.integers(0, len(vertices), (900, 2))
        data = {'map': 'fixture', 'spatialOrder': 'bvh-median-v1',
                'vertices': vertices.reshape(-1).tolist(), 'edges': edges.reshape(-1).tolist(),
                'layers': [{'elevationCm': level, 'globalOrigins': level == 100,
                            'edges': rng.choice(len(edges), 300, replace=False).tolist()}
                           for level in (100, 110, 120)]}
        original = copy.deepcopy(data)
        result = order_tables(data)
        self.assertEqual(data, original)
        self.assertEqual(result['spatialOrder'], data['spatialOrder'])
        points = np.asarray(result['vertices']).reshape(-1, 2)
        lines = np.asarray(result['edges']).reshape(-1, 2)
        for before, after in zip(data['layers'], result['layers']):
            self.assertEqual(before['elevationCm'], after['elevationCm'])
            self.assertEqual(before['globalOrigins'], after['globalOrigins'])
            np.testing.assert_equal(vertices[edges[before['edges']]], points[lines[after['edges']]])

    def test_empty_geometry_and_empty_layers_are_preserved(self):
        data = {'vertices': [], 'edges': [], 'layers': [{'elevationCm': 175, 'edges': []}]}
        self.assertEqual(order_tables(data), data)

    def test_extreme_int32_coordinates_and_duplicate_sort_keys_are_stable(self):
        points = np.array([[-2**31, -2**31], [2**31-1, 2**31-1],
                           [-2**31, -2**31], [0, 0]], dtype=np.int64)
        np.testing.assert_equal(spatial_order(points), [0, 2, 3, 1])
        data = {'vertices': points.reshape(-1).tolist(), 'edges': [0, 1, 1, 0],
                'layers': [{'elevationCm': 175, 'edges': [1, 0]}]}
        result = order_tables(data)
        vertices = np.array(result['vertices']).reshape(-1, 2)
        edges = np.array(result['edges']).reshape(-1, 2)
        np.testing.assert_equal(vertices[edges[result['layers'][0]['edges']]], points[[[1, 0], [0, 1]]])


if __name__ == '__main__':
    unittest.main()
