"""Validate the blank-band metric independently of a particular map image."""
import unittest
import numpy as np
from audit_wall_contact_pixels import pixel_gap


class WallContactPixelTests(unittest.TestCase):
    def test_touching_coverage_has_no_blank_pixel(self):
        ink = np.array([0, 0, 255, 0, 0, 0], dtype=np.uint8)
        cone = np.array([0, 0, 0, 255, 255, 255], dtype=np.uint8)
        self.assertEqual(pixel_gap(ink, cone, np.arange(6), 2.5, 1, 1)['blankPixels'], 0)

    def test_two_pixel_gap_is_not_excused_as_antialiasing(self):
        ink = np.array([0, 0, 255, 0, 0, 0, 0], dtype=np.uint8)
        cone = np.array([0, 0, 0, 0, 0, 255, 255], dtype=np.uint8)
        self.assertEqual(pixel_gap(ink, cone, np.arange(7), 2.5, 1, 1)['blankPixels'], 2)
        self.assertEqual(pixel_gap(ink[::-1], cone[::-1], np.arange(7), 4.5, -1, 1)['blankPixels'], 2)

    def test_single_alpha_level_counts_as_coverage(self):
        ink = np.array([0, 255, 1, 0, 0, 0], dtype=np.uint8)
        cone = np.array([0, 0, 0, 1, 255, 255], dtype=np.uint8)
        self.assertEqual(pixel_gap(ink, cone, np.arange(6), 1.5, 1, 1)['blankPixels'], 0)

    def test_absent_wall_or_cone_cannot_silently_pass(self):
        zero = np.zeros(7, dtype=np.uint8)
        ink = zero.copy(); ink[2] = 255
        self.assertIsNone(pixel_gap(zero, ink, np.arange(7), 2.5, 1, 1))
        self.assertEqual(pixel_gap(ink, zero, np.arange(7), 2.5, 1, 1)['status'], 'no-cone-in-profile')

    def test_tiny_fringe_cannot_close_a_gap_for_acceptance(self):
        ink = np.array([0, 0, 255, 0, 0, 0, 0], dtype=np.uint8)
        for fringe in ([1, 1, 255, 255], [1, 255, 255, 255]):
            cone = np.array([0, 0, 0, *fringe], dtype=np.uint8)
            result = pixel_gap(ink, cone, np.arange(7), 2.5, 1, 1)
            self.assertEqual(result['blankPixels'], 0)
            self.assertFalse(result['coverageContactPassed'])
            self.assertGreater(result['coverageDeficitPixels'], .9)

    def test_aligned_area_coverage_survives_subpixel_phase_and_quantization(self):
        # Independent analytic pixel area of a centered gold stroke and an
        # inward half-plane cone. A one-physical-pixel shift bounds raster
        # quantization; it is not an allowed world-space wall displacement.
        ys = np.arange(20)
        for scale in (1., 2., 8.):
            for phase in np.linspace(0, 1, 41):
                center = 8 + phase
                ink = np.rint(255 * np.maximum(0., np.minimum(ys + 1, center + .5 * scale) -
                                               np.maximum(ys, center - .5 * scale))).astype(np.uint8)
                for shift in (0., .5, 1.):
                    cone = np.rint(255 * np.clip(ys + 1 - center - shift, 0, 1)).astype(np.uint8)
                    result = pixel_gap(ink, cone, ys, center, 1, scale)
                    self.assertIsNotNone(result)
                    self.assertEqual(result['blankPixels'], 0, (scale, phase, shift, result))
                    self.assertTrue(result['coverageContactPassed'], (scale, phase, shift, result))


if __name__ == '__main__':
    unittest.main()
