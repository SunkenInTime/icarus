from contextlib import redirect_stdout
from io import StringIO
import unittest

from world_visibility_height_calibration import CachedCaster, calibrate, compare_heights, nearest_layer


def height_sensitive_cast(origin, direction, distance):
    hit = origin[2] * 20
    return {'distanceMeters': hit, 'hitMeters': [hit, 0, origin[2]], 'materialCertain': True}


class HeightCalibrationTests(unittest.TestCase):
    def test_nearest_plane_ties_choose_lower_and_endpoints_clamp(self):
        self.assertEqual(nearest_layer([175, 180, 185], 177.5), 0)
        self.assertEqual(nearest_layer([175, 180, 185], 177.50001), 1)
        self.assertEqual(nearest_layer([175, 180, 185], 100), 0)
        self.assertEqual(nearest_layer([175, 180, 185], 200), 2)

    def test_refinement_subdivides_the_interval_without_inserting_sample_height(self):
        origins = [{'id': 0, 'positionMeters': [0, 0, .0323]}]
        cast = CachedCaster(height_sensitive_cast)
        with redirect_stdout(StringIO()):
            levels, rounds = calibrate(origins, [175, 180], cast, directions=4)
        self.assertEqual(levels, [175, 176, 177, 178, 179, 180])
        self.assertNotIn(178.23, levels)
        self.assertEqual(len(rounds), 2)
        self.assertEqual(rounds[0]['summary']['within10CmFraction'], 0)
        self.assertEqual(rounds[-1]['summary']['within10CmFraction'], 1)
        self.assertEqual(rounds[-1]['summary']['within2CmFraction'], 0)
        self.assertGreater(cast.hits, 0)

    def test_verification_reports_new_failures_without_changing_levels(self):
        levels = [175, 176, 177, 178, 179, 180]
        before = levels.copy()
        # Deliberately stronger sensitivity produces a new held-out failure.
        def steep(origin, direction, distance):
            return {'distanceMeters': (origin[2] - 1.7) * 200,
                    'hitMeters': [0, 0, 0], 'materialCertain': True}
        result = compare_heights([{'id': 7, 'positionMeters': [1, 2, .035]}], levels,
                                 CachedCaster(steep), eye_height_cm=175, directions=4,
                                 range_meters=65, phase=.1, label='verification')
        self.assertEqual(levels, before)
        self.assertEqual(len(result['failures']), 4)
        self.assertTrue(all(r['ray'].startswith('verification/') for r in result['failures']))

    def test_cast_exceptions_remain_in_denominator_and_report(self):
        def broken(origin, direction, distance):
            raise ValueError('specific source failure')
        cast = CachedCaster(broken)
        result = compare_heights([{'id': 0, 'positionMeters': [0, 0, 0]}], [175], cast,
                                 eye_height_cm=175, directions=4, range_meters=65,
                                 phase=0, label='calibration')
        self.assertEqual(result['summary']['rays'], 4)
        self.assertEqual(result['summary']['within10CmFraction'], 0)
        self.assertEqual(len(result['exceptions']), 4)
        self.assertEqual(cast.calls, 4)
        self.assertTrue(all('specific source failure' in r['trueRay']['castError']
                            for r in result['exceptions']))

    def test_uncertain_materials_are_reported_without_discarding_their_rays(self):
        def uncertain(origin, direction, distance):
            return {'distanceMeters': 3, 'hitMeters': [0, 0, 0], 'materialCertain': False}
        result = compare_heights([{'id': 0, 'positionMeters': [0, 0, 0]}], [175],
                                 CachedCaster(uncertain), eye_height_cm=175,
                                 directions=4, range_meters=65, phase=0, label='calibration')
        self.assertEqual(result['summary']['within10CmFraction'], 1)
        self.assertEqual(len(result['uncertainMaterialRays']), 4)


if __name__ == '__main__':
    unittest.main()
