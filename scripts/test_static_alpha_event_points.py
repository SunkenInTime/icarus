"""Threshold tangencies and black-border discontinuities are real event states."""
import unittest

import numpy as np

import static_alpha_sections as sections
from world_visibility_ray_reference import sample_alpha


class AlphaEventPointTests(unittest.TestCase):
    def test_isolated_quadratic_threshold_contact_is_retained(self):
        alpha = np.array([[0., 1.], [1., 0.]])
        uv0, uv1 = np.array([.25, .25]), np.array([.75, .75])
        policy = dict(wrapS='clamp', wrapT='clamp', threshold=.5)
        section = sections.build_alpha_section(alpha, uv0, uv1, policy)
        self.assertEqual(sample_alpha(alpha, [.5, .5], policy), .5)
        self.assertTrue(section.contains(.5))
        self.assertFalse(section.contains(.49))
        self.assertFalse(section.contains(.51))
        # A point contact is not a positive-length wall segment.
        self.assertEqual(len(sections.opaque_intervals(alpha, uv0, uv1, policy)), 0)

    def test_black_border_endpoints_do_not_inherit_exterior_opacity(self):
        alpha = np.ones((1, 1))
        uv0, uv1 = np.array([-1., .5]), np.array([2., .5])
        policy = dict(wrapS='black', wrapT='clamp', threshold=.7,
                      alphaScale=-.8, alphaBias=.9)
        section = sections.build_alpha_section(alpha, uv0, uv1, policy)
        for t, expected in [(0., True), (1 / 3, False), (.5, False),
                            (2 / 3, False), (1., True)]:
            actual = sample_alpha(alpha, uv0 + t * (uv1 - uv0), policy) >= .7
            self.assertEqual(actual, expected)
            self.assertEqual(section.contains(t), expected, t)
        for cut in (1 / 3, 2 / 3):
            for t in (cut - 1e-8, cut + 1e-8):
                expected = sample_alpha(alpha, uv0 + t * (uv1 - uv0), policy) >= .7
                self.assertEqual(section.contains(t), expected, t)


if __name__ == '__main__':
    unittest.main()
