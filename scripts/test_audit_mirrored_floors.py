import unittest
import numpy as np

from audit_mirrored_floors import classify_heights, clip_window


class MirroredFloorTests(unittest.TestCase):
    def test_coincident_and_hidden_surfaces_do_not_count_as_height_changes(self):
        self.assertEqual(classify_heights(3, 3, 3), 'coincident-selected-height')
        self.assertEqual(classify_heights(3, 3, 2.8), 'interior-or-occluded')
        self.assertEqual(classify_heights(3, 3.1, 3.1), 'selected-height-changed')
        self.assertEqual(classify_heights(3, None, 3), 'lost-eligible-coverage')

    def test_original_vertical_window_rejects_roofs_and_deep_interiors(self):
        nav = np.array([[0., 0., 0.], [2., 0., 0.], [0., 2., 0.]])
        for height in [-.7, .4]:
            surface = nav + [0, 0, height]
            self.assertIsNone(clip_window(surface, nav))
        for height in [-.6, .3]:
            self.assertAlmostEqual(clip_window(nav + [0, 0, height], nav).area, 2)


if __name__ == '__main__':
    unittest.main()
