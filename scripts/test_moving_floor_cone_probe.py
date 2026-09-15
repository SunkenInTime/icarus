"""Analytic checks for the diagnostic cone's radial interpolation."""
import unittest
import numpy as np
from probe_moving_floor_cones import radial_chord, build_cone


class MovingConeProbeTest(unittest.TestCase):
    def test_straight_wall_interpolates_exactly(self):
        for angle in np.linspace(-.6, .6, 21):
            self.assertAlmostEqual(radial_chord(-.6, 2/np.cos(.6), .6, 2/np.cos(.6), angle), 2/np.cos(angle), places=12)

    def test_range_circle_refines_to_tolerance(self):
        angles, ranges, cache, limited = build_cone(lambda _: 5., np.array([-.7, .7]), .001, 4096)
        self.assertFalse(limited)
        self.assertGreater(len(angles), 2)
        for i in range(len(angles)-1):
            middle = (angles[i]+angles[i+1])/2
            self.assertLessEqual(abs(radial_chord(angles[i], ranges[i], angles[i+1], ranges[i+1], middle)-5), .001)

    def test_budget_exhaustion_is_explicit(self):
        _, _, _, limited = build_cone(lambda _: 5., np.array([-.7, .7]), 1e-10, 4)
        self.assertTrue(limited)


if __name__ == '__main__':
    unittest.main()
