import copy
import json
import unittest

import numpy as np
import shapely

from apply_regional_standing_review import reviewed_domains


class StandingReviewTests(unittest.TestCase):
    def setUp(self):
        self.objects = [dict(path='source/fountain', firstFace=0, faceCount=1)]
        self.geometry = dict(points=np.array([[0., 0., 2.], [10., 0., 2.], [0., 10., 2.]]),
            faces=np.array([[0, 1, 2]]))
        self.entry = dict(samples=[dict(id='reviewed-center', sourceFace=0, sourceObject=0,
            sourcePath='source/fountain', nativeXY=[2.5, 2.5], renderedElevationMeters=2., physicalFloor=None)],
            exclusions=[dict(sourceObject=0, fillRule='evenodd',
                nativeRings=[[1, 1, 4, 1, 4, 4, 1, 4], [2, 2, 3, 2, 3, 3, 2, 3]])])

    def test_ring_keeps_center_and_outer_basin_and_clips_region(self):
        region = shapely.box(0, 0, 6, 6)
        domains, _ = reviewed_domains(self.entry, self.objects, self.geometry, [], {}, region)
        self.assertEqual(len(domains), 1)
        shape = shapely.from_geojson(json.dumps(domains[0]['nativeGeometry']))
        self.assertTrue(shape.covers(shapely.Point(2.5, 2.5)))
        self.assertTrue(shape.covers(shapely.Point(.5, .5)))
        self.assertFalse(shape.covers(shapely.Point(1.5, 1.5)))
        self.assertFalse(shape.covers(shapely.Point(7, 1)))
        self.assertEqual(domains[0]['nativePlane'], [0., 0., 2.])
        wrong = copy.deepcopy(self.entry)
        wrong['samples'][0]['sourcePath'] = 'unrelated/mesh'
        with self.assertRaises(AssertionError):
            reviewed_domains(wrong, self.objects, self.geometry, [], {}, region)

    def test_local_physical_floor_replaces_only_its_own_footprint(self):
        entry = copy.deepcopy(self.entry)
        entry['exclusions'] = []
        entry['samples'][0]['physicalFloor'] = dict(collision='physical', face=0,
            plane=[0., 0., 1.9], floorMeters=1.9)
        tri = np.array([[[2., 2., 1.9], [4., 2., 1.9], [2., 4., 1.9]]])
        domains, evidence = reviewed_domains(entry, self.objects, self.geometry,
            [dict(id='physical')], {'0': tri}, shapely.box(0, 0, 10, 10))
        self.assertEqual(len(domains), 2)
        physical = next(d for d in domains if d['heightBasis'] == 'matched-player-collision')
        visual = next(d for d in domains if d['heightBasis'] == 'reviewed-source-face')
        p, v = [shapely.from_geojson(json.dumps(d['nativeGeometry'])) for d in [physical, visual]]
        self.assertTrue(p.covers(shapely.Point(2.5, 2.5)))
        self.assertFalse(v.covers(shapely.Point(2.5, 2.5)))
        self.assertTrue(v.covers(shapely.Point(.5, .5)))
        self.assertAlmostEqual(p.union(v).area, 50.)
        self.assertIn('physical', evidence)
        tri[:, :, 2] += .1
        with self.assertRaises(AssertionError):
            reviewed_domains(entry, self.objects, self.geometry,
                [dict(id='physical')], {'0': tri}, shapely.box(0, 0, 10, 10))


if __name__ == '__main__':
    unittest.main()
