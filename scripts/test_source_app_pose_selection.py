import unittest

from build_source_app_cases import spread_poses


class PoseSelectionTests(unittest.TestCase):
    def test_distinct_sources_span_map_and_keep_saved_lower_level(self):
        def pose(key, xy, area, lower=False):
            result = dict(sourceDomain=key, nativeXY=xy, sourceAreaSquareMeters=area)
            if lower:
                result['savedReferenceEyeMeters'] = 1.75
            return result
        candidates = [pose('large-floor', [1., 1.], 1000.),
            pose('stacked', [0., 0.], 2., True), pose('stacked', [.1, .1], 2., True),
            pose('distant', [100., 100.], 1.), pose('third', [-100., 0.], 1.)]
        selected = spread_poses(candidates, 3)
        self.assertEqual([r['sourceDomain'] for r in selected], ['stacked', 'distant', 'third'])
        self.assertEqual(len(candidates), 5)


if __name__ == '__main__':
    unittest.main()
