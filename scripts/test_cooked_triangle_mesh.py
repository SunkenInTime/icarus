import struct
import unittest

import numpy as np

from cooked_triangle_mesh import triangle_mesh


def payload(indices=(0, 1, 2), large=False):
    header = struct.pack('<5iBiiBii', 4, 0, 1, 1, 0, 11, 0, 0, 11, 1, 3)
    vertices = np.array([[0, 0, 0], [1, 0, 0], [0, 1, 0]], dtype='<f4').tobytes()
    faces = struct.pack('<ii', int(large), 1) + np.array(indices, dtype='<u4' if large else '<u2').tobytes()
    return header + vertices + faces + bytes(24)


class CookedTriangleMeshTests(unittest.TestCase):
    def test_both_native_index_widths(self):
        for large in [False, True]:
            vertices, faces, evidence = triangle_mesh(payload(large=large))
            np.testing.assert_array_equal(faces, [[0, 1, 2]])
            np.testing.assert_array_equal(vertices[1], [1, 0, 0])
            self.assertEqual(evidence['indexWidthBytes'], 4 if large else 2)

    def test_truncation_and_invalid_indices_fail(self):
        for data in [payload()[:37], payload()[:50], payload()[:-25], payload((0, 1, 3))]:
            with self.assertRaises(ValueError):
                triangle_mesh(data)


if __name__ == '__main__':
    unittest.main()
