import unittest
import numpy as np
from experimental_floor_relative_visibility import (
    FloorPatch, first_hit, flatten_triangles, rectangle, surface, validate_chart, wall,
)


class FloorRelativeTests(unittest.TestCase):
    def setUp(self):
        self.ramp = FloorPatch(rectangle(0, 10), np.array([-.4, 0, 4.]))
        self.start = np.array([1., 0, self.ramp.height([1, 0]) + 1.75])
        self.end = np.array([9., 0, self.ramp.height([9, 0]) + 1.75])

    def test_downslope_horizontal_plane_hits_ceiling_but_eye_to_eye_and_chart_are_clear(self):
        geometry = np.concatenate([surface(self.ramp), surface(self.ramp, 3)])
        horizontal_end = self.end.copy()
        horizontal_end[2] = self.start[2]
        self.assertIsNotNone(first_hit(geometry, self.start, horizontal_end))
        self.assertIsNone(first_hit(geometry, self.start, self.end))
        flat, _, _ = flatten_triangles(geometry, [self.ramp])
        self.assertIsNone(first_hit(flat, [1, 0, 1.75], [9, 0, 1.75]))

    def test_tall_ramp_wall_remains_a_blocker(self):
        geometry = wall(5, self.ramp.height([5, 0]), 2)
        flat, _, _ = flatten_triangles(geometry, [self.ramp])
        self.assertIsNotNone(first_hit(geometry, self.start, self.end))
        self.assertIsNotNone(first_hit(flat, [1, 0, 1.75], [9, 0, 1.75]))

    def test_low_ramp_wall_stays_below_standing_eyes(self):
        geometry = wall(5, self.ramp.height([5, 0]), 1.2)
        flat, _, _ = flatten_triangles(geometry, [self.ramp])
        self.assertIsNone(first_hit(geometry, self.start, self.end))
        self.assertIsNone(first_hit(flat, [1, 0, 1.75], [9, 0, 1.75]))

    def test_raised_platform_is_not_used_as_a_replacement_ground_floor(self):
        lower_ground = FloorPatch(rectangle(0, 10), np.array([0., 0, 0]))
        platform = np.concatenate([wall(4, 0, 2.5),
            surface(FloorPatch(rectangle(4, 6), np.array([0., 0, 2.5])))])
        flat, _, _ = flatten_triangles(platform, [lower_ground])
        self.assertIsNotNone(first_hit(flat, [1, 0, 1.75], [9, 0, 1.75]))

    def test_overlapping_bridge_and_ground_require_separate_sheets(self):
        lower = FloorPatch(rectangle(0, 10), np.array([0., 0, 0]))
        upper = FloorPatch(rectangle(4, 6), np.array([0., 0, 3]))
        with self.assertRaisesRegex(ValueError, 'separate charts'):
            validate_chart([lower, upper])

    def test_crest_is_a_counterexample_to_global_floor_flattening(self):
        up = FloorPatch(rectangle(0, 5), np.array([.8, 0, 0]))
        down = FloorPatch(rectangle(5, 10), np.array([-.8, 0, 8]))
        ground = np.concatenate([surface(up), surface(down)])
        start, end = [1, 0, 2.55], [9, 0, 2.55]
        self.assertIsNotNone(first_hit(ground, start, end))
        flat, _, _ = flatten_triangles(ground, [up, down])
        self.assertIsNone(first_hit(flat, [1, 0, 1.75], [9, 0, 1.75]))

    def test_triangle_cuts_keep_source_barycentrics_and_alpha_holes(self):
        left = FloorPatch(rectangle(0, 5), np.array([-.4, 0, 4.]))
        right = FloorPatch(rectangle(5, 10), np.array([-.4, 0, 4.]))
        fence = wall(5, 2, 2.5)
        flat, source_ids, weights = flatten_triangles(fence, [left, right])
        source_uvs = np.array([[[0, 0], [1, 0], [1, 1]], [[0, 0], [1, 1], [0, 1]]])
        uvs = np.einsum('fij,fjk->fik', weights, source_uvs[source_ids])
        source_positions = np.einsum('fij,fjk->fik', weights, fence[source_ids])
        np.testing.assert_allclose(source_positions[:, :, :2], flat[:, :, :2], atol=1e-14)
        np.testing.assert_allclose(source_positions[:, :, 2] - left.height(flat[:, :, :2]), flat[:, :, 2], atol=1e-14)
        def source_hole(index, barycentric):
            u = barycentric @ source_uvs[index, :, 0]
            return .4 < u < .6
        def flat_hole(index, barycentric):
            u = barycentric @ uvs[index, :, 0]
            return .4 < u < .6
        for y, blocked in [(0, False), (1.4, True)]:
            original = first_hit(fence, [1, y, self.start[2]], [9, y, self.end[2]], source_hole)
            transformed = first_hit(flat, [1, y, 1.75], [9, y, 1.75], flat_hole)
            self.assertEqual(original is not None, blocked)
            self.assertEqual(transformed is not None, blocked)


if __name__ == '__main__':
    unittest.main()
