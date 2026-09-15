import unittest
import numpy as np
from review_icebox_gameplay_openings import vertical_intervals


class VerticalIntervalsTest(unittest.TestCase):
    def test_base_and_header_do_not_fill_the_window(self):
        triangles = np.array([
            [[0, 0, 1], [0, 2, 1], [0, 2, 5]],
            [[0, 0, 1], [0, 2, 5], [0, 0, 5]],
            [[0, 0, 8], [0, 2, 8], [0, 2, 10]],
            [[0, 0, 8], [0, 2, 10], [0, 0, 10]],
        ], dtype=float)
        self.assertEqual(vertical_intervals(triangles, 0, [-.1, .1], [.5, 1.5]), [[1, 5], [8, 10]])

    def test_adjacent_column_does_not_close_the_entire_opening(self):
        triangles = np.array([[[0, 0, 1], [0, .2, 1], [0, .2, 10]]], dtype=float)
        self.assertEqual(vertical_intervals(triangles, 0, [-.1, .1], [.5, 1.5]), [])
        self.assertEqual(vertical_intervals(triangles, 0, [-.1, .1], [0, .2]), [[1, 10]])


if __name__ == '__main__':
    unittest.main()
