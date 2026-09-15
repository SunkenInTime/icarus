import unittest
import numpy as np
import shapely

from horizontal_mesh_slice import slice_triangles
from world_geometry_bake import intersect_triangles, planarize_segments, floor_ranges_by_polygon, standing_elevations


class WorldGeometryBakeTests(unittest.TestCase):
    def test_vectorized_slices_match_independent_triangle_walker(self):
        triangles = np.random.default_rng(22).uniform(-4, 4, (500, 3, 3))
        for elevation in [-1, 0, 1]:
            expected, ids, _ = slice_triangles(triangles, elevation)
            actual, actual_ids, _ = intersect_triangles(triangles, elevation)
            self.assertEqual(set(ids), set(actual_ids))
            for segment, index in zip(actual, actual_ids):
                other = np.array(expected[ids.index(index)])
                self.assertLess(min(np.max(abs(segment - other)), np.max(abs(segment - other[::-1]))), 1e-10)

    def test_exact_top_and_bottom_edges_survive(self):
        triangles = np.array([[[0, 0, 0], [2, 0, 0], [0, 1, -2]],
                              [[0, 0, 0], [2, 0, 0], [0, 1, 2]]], dtype=float)
        segments, ids, _ = intersect_triangles(triangles, 0)
        self.assertEqual(set(ids), {0, 1})
        for segment in segments:
            np.testing.assert_equal(sorted(segment.tolist()), [[0, 0], [2, 0]])

    def test_crossing_planarization_keeps_junction_and_merges_duplicate_edges(self):
        ui = {'XMultiplier': -0.01, 'YMultiplier': 0.01, 'XScalarToAdd': 0, 'YScalarToAdd': 0}
        segments = np.array([[[-1, 0], [1, 0]], [[0, -1], [0, 1]], [[-1, 0], [0, 0]]], dtype=float)
        lines = planarize_segments(segments, ui, 1)
        self.assertEqual(len(lines), 4)
        self.assertTrue(all((0, 0) in edge for edge in lines))
        self.assertAlmostEqual(shapely.union_all(shapely.linestrings(lines)).length, 4)

    def test_texture_interpolation_follows_face_edge(self):
        triangles = np.array([[[0, 0, 0], [2, 0, 0], [0, 2, 2]]], dtype=float)
        texture = np.array([[[0, 0], [1, 0], [0, 1]]], dtype=float)
        segments, _, uvs = intersect_triangles(triangles, 1, texture)
        np.testing.assert_allclose(segments[0] / 2, uvs[0])

    def test_floor_ranges_include_detail_fallback_and_separate_stacked_polygons(self):
        nav = {'polygons': [[0, 1, 2], [3, 4, 5]], 'triangles': [0, 0, 1, 2, 1, 3, 4, 5]}
        refinement = {'refinedFloorHeightsCm': [0, 10, 20, 300, 310, 320]}
        floor = {'vertices': [0, 0, -5, 1, 0, 30, 0, 1, 5,
                              0, 0, 300, 1, 0, 315, 0, 1, 325],
                 'triangles': [0, 0, 1, 2, 1, 3, 4, 5]}
        minimum, maximum = floor_ranges_by_polygon(nav, refinement, floor)
        np.testing.assert_equal(minimum, [-5, 300])
        np.testing.assert_equal(maximum, [30, 325])

    def test_height_spacing_covers_slopes_and_keeps_common_flat_floor(self):
        floor = {'vertices': [0, 0, 12.34, 10, 0, 12.34, 0, 10, 12.34,
                              10, 10, 31], 'triangles': [0, 0, 1, 2, 0, 1, 2, 3]}
        levels = standing_elevations({}, {'refinedFloorHeightsCm': [12.34, 31]}, floor, 175, 5)
        self.assertIn(187.34, levels)
        self.assertLessEqual(levels[0], 187.34)
        self.assertGreaterEqual(levels[-1], 206)
        self.assertLessEqual(max(np.diff(levels)), 5)


if __name__ == '__main__':
    unittest.main()
