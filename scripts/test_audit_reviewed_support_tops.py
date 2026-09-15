import unittest

import numpy as np

from audit_reviewed_support_tops import selected_surface_triangles


class SelectedFloorTests(unittest.TestCase):
    def setUp(self):
        self.archive = dict(
            points=np.array([[0, 0, 2], [1, 0, 2], [0, 1, 2],
                             [0, 0, 8], [1, 0, 8], [0, 1, 8]]),
            faces=np.array([[0, 1, 2], [3, 4, 5]]))
        self.objects = [dict(firstFace=0, faceCount=2)]

    def test_lower_platform_is_not_replaced_by_overhead_surface(self):
        lower = selected_surface_triangles(self.archive, self.objects,
            dict(sourceObjects=[0], sourceTopFaces=[0]))
        self.assertEqual(lower.shape, (1, 3, 3))
        self.assertTrue((lower[:, :, 2] == 2).all())

    def test_selected_faces_must_belong_to_declared_source(self):
        with self.assertRaisesRegex(ValueError, 'does not belong'):
            selected_surface_triangles(self.archive,
                [dict(firstFace=0, faceCount=1)],
                dict(sourceObjects=[0], sourceTopFaces=[1]))


if __name__ == '__main__':
    unittest.main()
