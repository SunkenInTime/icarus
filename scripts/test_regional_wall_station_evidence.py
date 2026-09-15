import unittest
import copy
import numpy as np

from verify_icebox_regional_walls import equal, gameplay_intervals, local_station_expectations, verify_facade_record


class StationEvidenceTest(unittest.TestCase):
    def test_floor_transition_does_not_inherit_remote_mesh_top(self):
        decision = dict(mode='connected-ground', maximumSourceZ=13.736652374267578,
                        floorElevationMeters=2.)
        self.assertEqual(gameplay_intervals(decision), [])
        self.assertFalse(equal([[None, decision['maximumSourceZ']]], gameplay_intervals(decision)))
        decision['mode'] = 'source-height'
        self.assertEqual(gameplay_intervals(decision), [[None, 13.736652374267578]])
        decision['bandsAboveFloor'] = []
        self.assertEqual(gameplay_intervals(decision), [])
        decision['bandsAboveFloor'] = [[0, 2], [3, 5]]
        self.assertEqual(gameplay_intervals(decision), [[None, 4], [5, 7]])

    def sample(self, top, distance, point=(3., 4.)):
        return dict(svg=point, associationSvg=point, status='measured-facade',
                    measuredTopMeters=top, registrationDistanceMeters=distance)

    def test_opposite_edges_use_closest_registered_section(self):
        parent = dict(stations=[self.sample(16.4751, .059), self.sample(15.86224, 0.)])
        expected, resolutions = local_station_expectations(parent, [0, 1])
        self.assertEqual(expected, [[[None, 15.86224]]])
        self.assertEqual(resolutions[0]['selectedSourceStationIndices'], [1])

    def test_equal_quality_disagreement_cannot_pass(self):
        parent = dict(stations=[self.sample(16., 0.), self.sample(15., 0.)])
        expected, _ = local_station_expectations(parent, [0, 1])
        self.assertFalse(all(equal([[None, 15.]], item) for item in expected))

    def test_distinct_locations_retain_both_obligations(self):
        parent = dict(stations=[self.sample(16., .1), self.sample(15., 0., (4., 4.))])
        expected, resolutions = local_station_expectations(parent, [0, 1])
        self.assertEqual(len(expected), 2)
        self.assertEqual(resolutions, [])

    def test_shared_facade_rejects_wrong_height_and_foreign_face(self):
        objects = [dict(path='wall', firstFace=0, faceCount=1)]
        geometry = dict(points=np.array([[0., 0., 0.], [1., 0., 0.], [0., 0., 6.]]),
                        faces=np.array([[0, 1, 2], [0, 1, 2]]))
        record = dict(originalWallId='painted-wall', sourceObject=0, sourcePath='wall',
                      domainRings=[[0, 0, 1, 0, 1, 1]],
                      samples=[dict(faces=[0], native=[0., 0.], measuredBands=[[0., 6.]])], measuredTopMeters=6.)
        verify_facade_record(record, objects, geometry, np.array([1., 0.]))
        for change in [dict(measuredTopMeters=6.25), dict(samples=[dict(faces=[1])]),
                       dict(samples=[dict(faces=[0], native=[0., 0.], measuredBands=[[0., 6.25]])]),
                       dict(sourcePath='other-wall'), dict(samples=[])]:
            with self.subTest(change=change), self.assertRaises(AssertionError):
                verify_facade_record(dict(copy.deepcopy(record), **change), objects, geometry, np.array([1., 0.]))

    def test_shared_facade_uses_clipped_section_not_remote_triangle_peak(self):
        objects = [dict(path='sloped-wall', firstFace=0, faceCount=1)]
        geometry = dict(points=np.array([[0., 0., 0.], [0., 0., 4.], [2., 0., 8.]]),
                        faces=np.array([[0, 1, 2]]))
        record = dict(originalWallId='painted-wall', sourceObject=0, sourcePath='sloped-wall',
            domainRings=[[0, 0, 1, 0, 1, 1]], measuredTopMeters=4.4,
            samples=[dict(faces=[0], native=[0., 0.], measuredBands=[[0., 4.4]]),
                     dict(faces=[0], native=[.2, 0.], measuredBands=[[0., 4.8]])])
        verify_facade_record(record, objects, geometry, np.array([1., 0.]))
        with self.assertRaises(AssertionError):
            verify_facade_record(dict(record, measuredTopMeters=8.), objects, geometry, np.array([1., 0.]))


if __name__ == '__main__':
    unittest.main()
