import unittest
from refine_world_elevations import refine


class HeightRefinementTests(unittest.TestCase):
    def test_subdivides_complete_failed_interval_without_inserting_test_height(self):
        levels, summary = refine([100, 105, 110], [{'ray': 'probe', 'errorMeters': 4,
            'layerIndex': 1, 'layerElevationCm': 105, 'elevationCm': 103.23}])
        self.assertEqual(levels, [100, 101, 102, 103, 104, 105, 110])
        self.assertNotIn(103.23, levels)
        self.assertEqual(summary['addedPlanes'], 4)

    def test_exact_height_errors_require_geometry_investigation(self):
        levels, summary = refine([100, 105], [{'ray': 'broken', 'errorMeters': 4,
            'layerIndex': 1, 'layerElevationCm': 105, 'elevationCm': 105}])
        self.assertEqual(levels, [100, 105])
        self.assertEqual(summary['exactHeightErrors'], ['broken'])


if __name__ == '__main__':
    unittest.main()
