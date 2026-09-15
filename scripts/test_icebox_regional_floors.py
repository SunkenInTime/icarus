import unittest
import numpy as np
import shapely

from verify_icebox_regional_floors import svg_plane, compare


class RegionalFloorTests(unittest.TestCase):
    def test_removing_all_local_ground_reports_missing_floor(self):
        import json
        source = dict(domains=[dict(id='floor', nativePlane=[0, 0, 2],
            nativeGeometry=json.loads(shapely.to_geojson(shapely.box(1, 1, 3, 3))))])
        model = dict(version=3, ground=dict(vertices=[0, 0, 2, 10, 0, 2, 0, 10, 2],
            triangles=[], standingTriangles=[]),
            receiver=[dict(rings=[[0, 0, 10, 0, 10, 10, 0, 10]], fillRule='evenodd')],
            walls=[], supports=[])
        row = compare(source, model, np.array([[1., 0., 0.], [0., 1., 0.]]), 'attack')[0]
        self.assertEqual(row['status'], 'missing-level')
        self.assertEqual(row['defaultStatus'], 'wrong-default')
        self.assertEqual(row['missingAreaSvg'], 4)

    def test_shadowed_physical_ground_cannot_establish_the_default(self):
        import json
        source = dict(domains=[dict(id='floor', nativePlane=[0, 0, 2],
            nativeGeometry=json.loads(shapely.to_geojson(shapely.box(1, 1, 3, 3))))])
        model = dict(version=3, ground=dict(vertices=[0, 0, 4, 10, 0, 4, 0, 10, 4,
            0, 0, 2, 10, 0, 2, 0, 10, 2], triangles=[0, 1, 2, 3, 4, 5], standingTriangles=[1]),
            receiver=[dict(rings=[[0, 0, 10, 0, 10, 10, 0, 10]], fillRule='evenodd')],
            walls=[], supports=[])
        row = compare(source, model, np.array([[1., 0., 0.], [0., 1., 0.]]), 'attack')[0]
        self.assertEqual(row['status'], 'missing-level')
        self.assertEqual(row['defaultStatus'], 'wrong-default')
        self.assertEqual(row['missingAreaSvg'], 4)

    def test_correct_available_level_cannot_hide_inflated_ground_default(self):
        import json
        shape = dict(rings=[[0, 0, 10, 0, 10, 10, 0, 10]], fillRule='evenodd')
        source = dict(domains=[dict(id='floor', nativePlane=[0, 0, 2],
            nativeGeometry=json.loads(shapely.to_geojson(shapely.box(1, 1, 3, 3))))])
        model = dict(ground=dict(vertices=[0, 0, 2.1, 10, 0, 2.1, 0, 10, 2.1], triangles=[0, 1, 2]),
            receiver=[shape], walls=[], supports=[dict(shape, automaticStandingAllowed=True, surfaceElevationMeters=2)])
        row = compare(source, model, np.array([[1., 0., 0.], [0., 1., 0.]]), 'attack')[0]
        self.assertEqual(row['status'], 'passed')
        self.assertEqual(row['defaultStatus'], 'wrong-default')
        self.assertAlmostEqual(row['defaultMissingAreaSvg'], 4)
        model['ground']['vertices'][2::3] = [2, 2, 2]
        self.assertEqual(compare(source, model, np.array([[1., 0., 0.], [0., 1., 0.]]), 'attack')[0]['defaultStatus'], 'passed')

    def test_stacked_lower_floor_is_required_but_does_not_become_default(self):
        import json
        shape = dict(rings=[[0, 0, 10, 0, 10, 10, 0, 10]], fillRule='evenodd')
        source = dict(domains=[dict(id=str(z), nativePlane=[0, 0, z],
            nativeGeometry=json.loads(shapely.to_geojson(shapely.box(1, 1, 3, 3)))) for z in [0, 4]])
        model = dict(ground=dict(vertices=[0, 0, 0, 10, 0, 0, 0, 10, 0], triangles=[0, 1, 2]),
            receiver=[shape], walls=[], supports=[dict(shape, automaticStandingAllowed=True, surfaceElevationMeters=4)])
        rows = compare(source, model, np.array([[1., 0., 0.], [0., 1., 0.]]), 'attack')
        self.assertEqual(rows[0]['defaultAreaSvg'], 0)
        self.assertEqual(rows[1]['defaultAreaSvg'], 4)
        self.assertTrue(all(r['defaultStatus'] == 'passed' and r['status'] == 'passed' for r in rows))

    def test_plane_conversion_preserves_source_height_on_both_artwork_orientations(self):
        plane = np.array([.3, -.2, 4.5])
        for matrix in [np.array([[2., .1, 80.], [-.1, 2., 140.]]),
                       np.array([[-2., -.1, 320.], [.1, -2., 460.]])]:
            transformed = svg_plane(plane, matrix)
            for point in [np.array([-51., -24.]), np.array([5., 9.])]:
                svg = matrix[:, :2] @ point + matrix[:, 2]
                self.assertAlmostEqual(transformed[:2] @ svg + transformed[2], plane[:2] @ point + plane[2])

    def test_thin_missing_floor_far_from_correct_floor_is_not_rounding(self):
        source = dict(domains=[dict(id='thin-ledge', nativePlane=[0, 0, 2],
            nativeGeometry=shapely.to_geojson(shapely.box(2, 2, 2.0005, 4)))])
        import json
        source['domains'][0]['nativeGeometry'] = json.loads(source['domains'][0]['nativeGeometry'])
        model = dict(ground=dict(vertices=[0, 0, 0, 10, 0, 0, 0, 10, 0], triangles=[0, 1, 2]),
            receiver=[dict(rings=[[0, 0, 10, 0, 10, 10, 0, 10, 0, 0]], fillRule='evenodd')],
            supports=[], walls=[])
        row = compare(source, model, np.array([[1., 0., 0.], [0., 1., 0.]]), 'attack')[0]
        self.assertEqual(row['status'], 'missing-level')
        self.assertGreater(row['missingAreaSvg'], .0009)


if __name__ == '__main__':
    unittest.main()
