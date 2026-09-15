"""Independent boundary, layer and broadphase controls for the offline prototype."""
from fractions import Fraction
import unittest
from unittest.mock import patch
import numpy as np
import shapely

from experimental_floor_relative_visibility import first_hit, rectangle, wall
from finite_receiver_shadows import Receiver, build_shadows, renderer_mesh_checked
from finite_shadow_broadphase import candidates, swept_bounds


def shape(rows, index=None):
    selected = [shapely.Polygon(row['polygon']) for row in rows if index is None or row['receiver'] == index]
    return shapely.union_all(selected) if selected else shapely.Polygon()


class ShadowContracts(unittest.TestCase):
    def test_float32_collapse_and_sign_flip_keep_source_identities(self):
        collapse = np.array([[2., 3.], [3., 3.], [3., 3.+1e-9]])
        reversal = np.array([[4.733242183774532, 1.1810439286820031],
                             [4.121077508220386, 1.78592379110384],
                             [4.506741249187227, 1.4048494870956687]])
        for face, polygon in [(71, collapse), (93, reversal)]:
            mesh, pending = renderer_mesh_checked([0, 0, 1.75], [dict(receiver=7, sourceFace=face, polygon=polygon)])
            self.assertEqual(len(mesh), 0)
            self.assertEqual(len(pending), 1)
            self.assertEqual((pending[0]['receiver'], pending[0]['sourceFace']), (7, face))
            self.assertIn('float32', pending[0]['reason'])

    def test_one_unrepresentable_fan_piece_defers_whole_source_face(self):
        polygon = np.array([[2., 3.], [3., 3.], [3., 4.], [3., 4.+1e-9]])
        mesh, pending = renderer_mesh_checked([0, 0, 1.75], [dict(receiver=0, sourceFace=19, polygon=polygon)])
        self.assertEqual(len(mesh), 0, 'Emitting the first valid triangle would only partly represent the source face')
        self.assertEqual(pending[0]['sourceFace'], 19)

    def test_exact_collinear_fan_piece_does_not_hide_valid_polygon(self):
        polygon = np.array([[0., 0.], [1., 0.], [2., 0.], [2., 2.]])
        mesh, pending = renderer_mesh_checked([0, 0, 1.75], [dict(receiver=0, sourceFace=8, polygon=polygon)])
        self.assertFalse(pending)
        self.assertEqual(len(mesh), 1)

    def test_nonempty_point_and_edge_contacts_are_not_silently_clear(self):
        receiver = Receiver(rectangle(0, 12), np.zeros(3))
        for polygon in [np.array([[4., 1.]]), np.array([[4., 1.], [4., 2.]])]:
            with patch('finite_receiver_shadows.shadow_triangle', return_value=(polygon, None)):
                rows, pending = build_shadows([0, 0, 1.75], wall(4, 0, 3)[:1], [receiver])
            self.assertFalse(rows)
            self.assertEqual(len(pending), 1)
            self.assertEqual(pending[0]['reason'], 'point-or-edge-contact-requires-source-fallback')

    def test_small_shadow_area_is_measured_in_local_coordinates(self):
        polygon = np.array([[40., 45.], [40.+1e-7, 45.], [40.+1e-7, 45.+1e-7], [40., 45.+1e-7]])
        receiver = Receiver(rectangle(0, 60), np.zeros(3))
        with patch('finite_receiver_shadows.shadow_triangle', return_value=(polygon, None)):
            rows, pending = build_shadows([0, 0, 1.75], wall(4, 0, 3)[:1], [receiver])
        self.assertEqual(len(rows), 1)
        self.assertFalse(pending)

    def test_real_split_thin_face_does_not_shadow_entire_receiver(self):
        # Complete V29 source pack318283ae...7d487, face927068; preserved
        # first-projection-disagreement.json in real-standing-receiver-probe-v1.
        eye = [52.38207199097103, 44.581586999299226, 5.38850711819371]
        triangle = np.array([[39.8878831467879, 45.53665701085224, 6.787950038909912],
                             [39.8878831467879, 45.68740504137767, 6.787950038909912],
                             [39.887883146787914, 45.50109627735987, 6.787950038909912]])
        receiver = Receiver(np.array([[47.75, 46.25480651855469],
                                      [38.84174728393555, 46.25480651855469],
                                      [47.75, 42.5]]),
                            np.array([1.6966912531723418e-17, 6.857665345989953e-06, 5.499682800016251]))
        target = [46.591927146911615, 45.61648941040039, 7.249995622634888]
        for face in [triangle, triangle[::-1]]:
            rows, pending = build_shadows(eye, face[None], [receiver])
            self.assertFalse(pending, 'The concrete thin face must be handled without removal/fallback')
            self.assertFalse(shapely.covers(shape(rows), shapely.Point(target[:2])))
            # Independent plane intersection gives X>48, separated from this
            # face at X39.887883 by meters; a tiny determinant cutoff is not needed.
            fraction = (triangle[0, 2]-eye[2])/(target[2]-eye[2])
            plane_x = eye[0] + fraction*(target[0]-eye[0])
            self.assertGreater(plane_x, triangle[:, 0].max()+8)

    def test_coplanar_near_coplanar_and_degenerate_are_explicit_fallback(self):
        receiver = Receiver(rectangle(0, 10), np.array([0., 0., 0.]))
        flat = np.array([[[3., -1., 1.75], [4., -1., 1.75], [3., 1., 1.75]]])
        for z in [1.75, np.nextafter(1.75, np.inf), 1.75 + 1e-12]:
            _, pending = build_shadows([1., 0., z], flat, [receiver])
            self.assertIn('coplanar', pending[0]['reason'])
        degenerate = np.array([[[3., 0., 0.], [3., 0., 0.], [3., 1., 3.]]])
        _, pending = build_shadows([1, 0, 1.75], degenerate, [receiver])
        self.assertEqual(pending[0]['reason'], 'degenerate-source-triangle')

    def test_receiver_partition_seam_preserves_whole_shadow(self):
        eye = [1., 0., 1.75]
        geometry = wall(4, 0, 3)
        whole = Receiver(rectangle(0, 12), np.zeros(3))
        parts = [Receiver(rectangle(0, 5), np.zeros(3)), Receiver(rectangle(5, 12), np.zeros(3))]
        expected, _ = build_shadows(eye, geometry, [whole])
        actual, pending = build_shadows(eye, geometry, parts)
        self.assertFalse(pending)
        self.assertLess(shapely.symmetric_difference(shape(expected), shape(actual)).area, 1e-12)
        for y in [-1., 0., 1.]:
            self.assertTrue(shapely.covers(shape(actual), shapely.Point(5, y)))

    def test_overlapping_layers_need_explicit_receiver_ownership(self):
        eye = [1., 0., 1.75]
        geometry = wall(4, 0, 3)
        receivers = [Receiver(rectangle(0, 12), np.array([0., 0., z])) for z in [0., 4.]]
        rows, pending = build_shadows(eye, geometry, receivers)
        self.assertFalse(pending)
        point = [8., 0.]
        self.assertIsNotNone(first_hit(geometry, eye, receivers[0].lift(point)))
        self.assertIsNone(first_hit(geometry, eye, receivers[1].lift(point)))
        self.assertTrue(shapely.covers(shape(rows, 0), shapely.Point(point)))
        self.assertFalse(shapely.covers(shape(rows, 1), shapely.Point(point)))
        # Demonstrates why the existing one-mask union is not a valid upper-layer result.
        mesh, quantized_fallback = renderer_mesh_checked(eye, rows)
        self.assertFalse(quantized_fallback)
        mesh = mesh.astype(float) + np.array(eye[:2])
        self.assertTrue(shapely.covers(shapely.union_all(shapely.polygons(mesh)), shapely.Point(point)))

    def test_transparent_mask_cannot_be_replaced_by_opaque_profile(self):
        eye, target = [1., 0., 1.75], [8., 0., 1.75]
        geometry = wall(4, 0, 3)
        receiver = Receiver(rectangle(0, 12), np.zeros(3))
        # Every hit in this frozen center strip is transparent. A solid frame
        # would remain a separate opaque source face in the real material path.
        self.assertIsNone(first_hit(geometry, eye, target, transparent=lambda face, bary: True))
        rows, _ = build_shadows(eye, geometry, [receiver])
        self.assertTrue(shapely.covers(shape(rows), shapely.Point(target[:2])))
        # Caller must route masked faces to an alpha-aware fallback; this API
        # explicitly accepts opaque triangles and does not carry material data.

    def test_outward_receiver_heights_cover_exact_rational_lift(self):
        rng = np.random.default_rng(173)
        receivers = [Receiver(rectangle(-173.1, 88.2, -59.4, 121.7), rng.uniform(-100, 100, 3)) for _ in range(100)]
        receivers += [
            Receiver(rectangle(1e-200, 2e-200, 0, 1), np.array([1e-200, 0., -1.75])),
            Receiver(rectangle(1., np.nextafter(1., np.inf), 1., np.nextafter(1., np.inf)), np.array([1e16, -1e16, -1.75])),
        ]
        for receiver in receivers:
            coefficients = receiver.floor_plane
            low, high = swept_bounds([0., 0., 0.], receiver)
            for x, y in receiver.footprint:
                z = (Fraction(float(coefficients[0])) * Fraction(float(x)) +
                     Fraction(float(coefficients[1])) * Fraction(float(y)) +
                     Fraction(float(coefficients[2])) + Fraction(receiver.standing_height))
                self.assertLessEqual(Fraction(float(low[2])), z)
                self.assertGreaterEqual(Fraction(float(high[2])), z)

    def test_broadphase_retains_all_bruteforce_shadow_faces_and_contacts(self):
        rng = np.random.default_rng(632)
        receiver = Receiver(rectangle(3, 10, -2, 2), np.array([.125, -.25, 0.]))
        eye = np.array([0., 0., 2.])
        triangles = rng.uniform([-4, -5, -3], [15, 5, 8], (200, 3, 3))
        ids = set(candidates(eye, receiver, triangles.min(1), triangles.max(1)).tolist())
        for index, triangle in enumerate(triangles):
            rows, _ = build_shadows(eye, [triangle], [receiver])
            if rows:
                self.assertIn(index, ids)
        low, high = swept_bounds(eye, receiver)
        touching_low = np.array([[low[0], -1, 0], [low[0], 1, 0], [low[0], 0, 3]])
        touching_high = touching_low.copy(); touching_high[:, 0] = high[0]
        exact_contacts = np.array([touching_low, touching_high])
        np.testing.assert_array_equal(candidates(eye, receiver, exact_contacts.min(1), exact_contacts.max(1)), [0, 1])


if __name__ == '__main__':
    unittest.main()
