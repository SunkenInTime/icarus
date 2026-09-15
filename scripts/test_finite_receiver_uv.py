"""Analytic and source-ray controls for finite receiver projective UVs."""
import unittest
import numpy as np

from experimental_floor_relative_visibility import first_hit, rectangle
from finite_receiver_shadows import Receiver
from finite_receiver_uv import build_projective_uv, ProjectiveUV
from world_visibility_ray_reference import ray_triangle, sample_alpha
from audit_receiver_uv_pixels import alpha_batch


class ReceiverUVContracts(unittest.TestCase):
    def test_pixel_batch_sampler_matches_frozen_scalar_policy(self):
        rng = np.random.default_rng(913)
        texture = rng.uniform(0, 1, (5, 7))
        uv = np.vstack([rng.uniform(-2, 3, (301, 2)), [[0,0],[1,1],[-1e-10,.5],[1+1e-10,.5]]])
        for wrap_s in ['repeat', 'mirror', 'clamp', 'black']:
            for wrap_t in ['repeat', 'mirror', 'clamp', 'black']:
                policy = dict(wrapS=wrap_s, wrapT=wrap_t, alphaScale=.73, alphaBias=.09, threshold=.333)
                expected = [sample_alpha(texture, point, policy) for point in uv]
                np.testing.assert_allclose(alpha_batch(texture, uv, policy), expected, rtol=0, atol=3e-16)

    def setUp(self):
        self.eye = np.array([0., 0., 2.])
        self.triangle = np.array([[4., -2., 0.], [4., 2., 0.], [4., -2., 4.]])
        self.uv = np.array([[0., 0.], [1., 0.], [0., 1.]])
        self.receiver = Receiver(rectangle(5, 12, -1, 0), np.zeros(3))

    def test_analytic_rational_uv_and_reversed_winding(self):
        for order in [[0, 1, 2], [2, 1, 0]]:
            mapping, polygon, reason = build_projective_uv(self.eye, self.triangle[order], self.uv[order], self.receiver)
            self.assertIsNone(reason); self.assertGreater(len(polygon), 2)
            for x in [5.5, 8., 11.5]:
                for y in [-.9, -.4, -.05]:
                    actual, reason = mapping.evaluate([x, y])
                    self.assertIsNone(reason)
                    np.testing.assert_allclose(actual, [.5+y/x, .5-.25/x], atol=2e-15, rtol=0)
                    target = self.receiver.lift([x, y]); direction = target-self.eye; direction /= np.linalg.norm(direction)
                    hit = ray_triangle(self.eye, direction, self.triangle)
                    self.assertIsNotNone(hit)
                    np.testing.assert_allclose(actual, np.array(hit[1])@self.uv, atol=2e-15, rtol=0)

    def test_threshold_and_coincident_opaque_face_are_preserved(self):
        mapping, _, reason = build_projective_uv(self.eye, self.triangle, self.uv, self.receiver)
        self.assertIsNone(reason)
        alpha = np.array([[0., 1.], [0., 1.]])
        policy = dict(wrapS='clamp', wrapT='clamp', threshold=.5)
        for y, opaque in [(-.2, False), (0., True)]:
            target = self.receiver.lift([8., y]); uv, reason = mapping.evaluate(target[:2])
            self.assertIsNone(reason)
            self.assertEqual(sample_alpha(alpha, uv, policy) >= .5, opaque)
            masked_only = first_hit(self.triangle[None], self.eye, target,
                                    transparent=lambda face, bary: sample_alpha(alpha, np.array(bary)@self.uv, policy) < .5)
            self.assertEqual(masked_only is not None, opaque)
            # A transparent sample never erases the coincident opaque face.
            coincident = first_hit(np.array([self.triangle, self.triangle]), self.eye, target,
                                   transparent=lambda face, bary: face == 0 and sample_alpha(alpha, np.array(bary)@self.uv, policy) < .5)
            self.assertIsNotNone(coincident)

    def test_wrap_modes_match_barycentric_sampler(self):
        uv = self.uv*np.array([3.2, 2.7]) + [-.9, -.8]
        mapping, _, reason = build_projective_uv(self.eye, self.triangle, uv, self.receiver)
        self.assertIsNone(reason)
        texture = np.array([[0., .2, .9], [1., .4, .1]])
        for wrap in ['repeat', 'mirror', 'clamp', 'black']:
            policy = dict(wrapS=wrap, wrapT=wrap, threshold=.5, alphaScale=.75, alphaBias=.1)
            for x, y in [(5.2, -.9), (8., -.4), (11., -.1)]:
                value, reason = mapping.evaluate([x, y]); self.assertIsNone(reason)
                target = self.receiver.lift([x, y]); direction = target-self.eye; direction /= np.linalg.norm(direction)
                _, bary = ray_triangle(self.eye, direction, self.triangle)
                expected = np.array(bary)@uv
                self.assertAlmostEqual(sample_alpha(texture, value, policy), sample_alpha(texture, expected, policy), places=13)

    def test_coplanar_degenerate_and_denominator_fallback_are_explicit(self):
        for triangle in [self.triangle[[0, 0, 2]], self.triangle-np.array([4., 0., 0.])]:
            mapping, polygon, reason = build_projective_uv(self.eye, triangle, self.uv, self.receiver)
            self.assertIsNone(mapping); self.assertIsNotNone(reason)
        mapping = ProjectiveUV(np.zeros(2), np.array([[1., 0., 0.], [0., 1., 0.], [1., 0., 0.]]))
        uv, reason = mapping.evaluate([0., 1.])
        self.assertIsNone(uv); self.assertIn('denominator', reason)


if __name__ == '__main__':
    unittest.main()
