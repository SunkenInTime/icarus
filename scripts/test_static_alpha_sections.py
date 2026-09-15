"""Check offline cuts against direct bilinear alpha sampling."""
import unittest
import numpy as np
from static_alpha_sections import opaque_intervals
from world_visibility_ray_reference import sample_alpha


class AlphaSectionsTest(unittest.TestCase):
    def test_analytic_linear_threshold(self):
        policy = dict(wrapS='clamp', wrapT='clamp', threshold=.25)
        intervals = opaque_intervals(np.array([[0., 1.]]), [.25, .5], [.75, .5], policy)
        np.testing.assert_allclose(intervals, [[.25, 1]], atol=1e-14)

    def test_quadratic_two_crossings(self):
        # Along the diagonal this checker is 2*t*(1-t).
        policy = dict(wrapS='clamp', wrapT='clamp', threshold=.375)
        intervals = opaque_intervals(np.array([[0., 1.], [1., 0.]]), [.25, .25], [.75, .75], policy)
        np.testing.assert_allclose(intervals, [[.25, .75]], atol=1e-14)

    def test_wrap_modes_scale_bias_and_reverse(self):
        rng = np.random.default_rng(701231)
        for wrap_s in ('clamp', 'repeat', 'mirror', 'black'):
            for wrap_t in ('clamp', 'repeat', 'mirror', 'black'):
                for scale in (1., -.8):
                    alpha = rng.integers(0, 256, (7, 11)) / 255.
                    endpoints = rng.uniform(-2, 3, (2, 2))
                    policy = dict(wrapS=wrap_s, wrapT=wrap_t, threshold=.43,
                                  alphaScale=scale, alphaBias=.1 if scale > 0 else .9)
                    intervals = opaque_intervals(alpha, *endpoints, policy)
                    for t in rng.random(1000):
                        expected = sample_alpha(alpha, endpoints[0] + t * (endpoints[1] - endpoints[0]), policy) >= policy['threshold']
                        actual = bool(np.any((intervals[:, 0] <= t) & (intervals[:, 1] >= t)))
                        self.assertEqual(actual, expected, (wrap_s, wrap_t, scale, t))
                    reversed_intervals = opaque_intervals(alpha, *endpoints[::-1], policy)
                    np.testing.assert_allclose(intervals, 1 - reversed_intervals[::-1, ::-1], atol=1e-11)

    def test_constant_uv_and_budget(self):
        policy = dict(wrapS='repeat', wrapT='clamp', threshold=.5)
        np.testing.assert_array_equal(opaque_intervals(np.ones((2, 2)), [.5, .5], [.5, .5], policy), [[0, 1]])
        self.assertEqual(len(opaque_intervals(np.zeros((2, 2)), [0, 0], [1, 1], policy)), 0)
        with self.assertRaises(ValueError):
            opaque_intervals(np.ones((2, 2)), [0, 0], [100, 0], policy, maximum_cells=10)


if __name__ == '__main__':
    unittest.main()
