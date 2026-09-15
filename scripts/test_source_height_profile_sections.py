import unittest
import numpy as np
from verify_source_height_profile_sections import merge_intervals, triangle_intervals, interval_error


class ProfileSectionTests(unittest.TestCase):
    def test_micro_gap_is_not_closed_by_interval_merge(self):
        gap = 1e-12
        self.assertEqual(merge_intervals([[0., 1.], [1.+gap, 2.]]), [[0., 1.], [1.+gap, 2.]])

    def test_hole_and_isolated_contact_are_detected(self):
        length, endpoint = interval_error([[0., 1.], [2., 3.]], [[0., 3.]])
        self.assertEqual(length, 1.)
        length, endpoint = interval_error([[0., 1.], [2., 2.]], [[0., 1.]])
        self.assertEqual(length, 0.)
        self.assertEqual(endpoint, 1.)

    def test_triangle_vertex_and_horizontal_base_contacts_survive(self):
        triangle = np.array([[[0., 0.], [2., 0.], [1., 2.]]])
        self.assertEqual(triangle_intervals(triangle, 0), [[0., 2.]])
        self.assertEqual(triangle_intervals(triangle, 1), [[.5, 1.5]])
        self.assertEqual(triangle_intervals(triangle, 2), [[1., 1.]])
        self.assertEqual(triangle_intervals(triangle, 3), [])


if __name__ == '__main__':
    unittest.main()
