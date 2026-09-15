"""A segment export must retain zero-width opacity and excluded endpoints."""
import unittest
import numpy as np
from static_alpha_sections import AlphaSection, masked_section_events


class AlphaSegmentEventsTest(unittest.TestCase):
    def test_isolated_contact_exports_a_point(self):
        lines, closed = masked_section_events(
            np.array([[0., 1.], [1., 0.]]), [[2., 4.], [6., 8.]],
            [[.25, .25], [.75, .75]], dict(wrapS='clamp', wrapT='clamp', threshold=.5))
        np.testing.assert_array_equal(lines, [[[4., 6.], [4., 6.]]])
        np.testing.assert_array_equal(closed, [[1, 1]])

    def test_black_border_exports_open_endpoints(self):
        lines, closed = masked_section_events(
            np.ones((1, 1)), [[0., 0.], [3., 0.]], [[-1., .5], [2., .5]],
            dict(wrapS='black', wrapT='clamp', threshold=.7, alphaScale=-.8, alphaBias=.9))
        np.testing.assert_allclose(lines, [[[0., 0.], [1., 0.]], [[2., 0.], [3., 0.]]], atol=1e-14)
        np.testing.assert_array_equal(closed, [[1, 0], [0, 1]])

    def test_transparent_internal_knot_splits_opaque_interval(self):
        section = AlphaSection(np.array([[0., 1.]]), np.array([.5]), np.array([False]))
        intervals, closed = section.pieces()
        np.testing.assert_array_equal(intervals, [[0., .5], [.5, 1.]])
        np.testing.assert_array_equal(closed, [[1, 0], [0, 1]])

    def test_degenerate_geometry_retains_opaque_contact(self):
        for alpha, count in [(np.ones((1, 1)), 1), (np.zeros((1, 1)), 0)]:
            lines, closed = masked_section_events(
                alpha, [[2., 3.], [2., 3.]], [[.5, .5], [.5, .5]],
                dict(wrapS='clamp', wrapT='clamp', threshold=.5))
            self.assertEqual(lines.shape, (count, 2, 2))
            self.assertEqual(closed.shape, (count, 2))
            if count:
                np.testing.assert_array_equal(lines, [[[2., 3.], [2., 3.]]])
                np.testing.assert_array_equal(closed, [[1, 1]])


if __name__ == '__main__':
    unittest.main()
