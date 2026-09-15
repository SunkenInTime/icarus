import unittest
import copy
import json
from pathlib import Path

import numpy as np
import shapely

from compile_icebox_physical_ground import emitted_ground_domains, lowest_domains, reconcile_supports
from compile_icebox_ramp_ground import replace_ground
from compile_reviewed_svg_height_map import polygon
from verify_icebox_physical_ground import verify_ground, verify_supports


class PhysicalGroundTests(unittest.TestCase):
    def test_source_level_remains_selectable_at_a_rounded_ground_edge(self):
        shape = shapely.box(0, 0, 4, 4)
        plane = np.array([0., 0., 2.])
        ground = dict(vertices=[0, 0, 2, 4, 0, 2, 0, 4, 2, 4, 4, 2],
                      triangles=[0, 1, 2, 1, 3, 2], standingTriangles=[0, 1])
        represented = emitted_ground_domains(ground, [[1, 0], [1, 0]], [(shape, plane)])
        supports, _ = reconcile_supports(dict(supports=[]),
            [(dict(id='floor'), shape, plane)], represented, shape)
        self.assertEqual(len(supports), 1)
        choice = polygon(supports[0])
        self.assertTrue(choice.covers(shapely.Point(2, 0)))
        self.assertFalse(choice.covers(shapely.Point(2, 2)))
        self.assertEqual(choice.difference(shape).area, 0)

    def test_hidden_ground_triangle_cannot_remove_a_source_level(self):
        shape = shapely.Polygon([(0, 0), (4, 0), (0, 4)])
        plane = np.array([0., 0., 2.])
        ground = dict(vertices=[0, 0, 6, 4, 0, 6, 0, 4, 6,
                                0, 0, 2, 4, 0, 2, 0, 4, 2],
                      triangles=[0, 1, 2, 3, 4, 5], standingTriangles=[1])
        represented = emitted_ground_domains(ground, [[0, 0], [1, 0]], [(shape, plane)])
        supports, _ = reconcile_supports(dict(supports=[]),
            [(dict(id='floor'), shape, plane)], represented, shape)
        self.assertEqual(len(supports), 1)
        self.assertAlmostEqual(polygon(supports[0]).symmetric_difference(shape).area, 0)

    def test_unemitted_ground_cannot_remove_a_source_level(self):
        shape = shapely.box(0, 0, 4, 4)
        plane = np.array([0., 0., 2.])
        ground = dict(vertices=[0, 0, 2, 4, 0, 2, 0, 4, 2],
                      triangles=[0, 1, 2], standingTriangles=[0])
        represented = emitted_ground_domains(ground, [[1, 0]], [(shape, plane)])
        supports, _ = reconcile_supports(dict(supports=[]),
            [(dict(id='floor'), shape, plane)], represented, shape)
        self.assertEqual(len(supports), 1)
        remaining = polygon(supports[0])
        self.assertTrue(remaining.covers(shapely.Point(3, 3)))
        self.assertFalse(remaining.covers(shapely.Point(1, 1)))
        missing = shape.difference(shapely.Polygon([(0, 0), (4, 0), (0, 4)]))
        self.assertEqual(missing.difference(remaining).area, 0)

    def test_coincident_edges_cannot_invent_ground_coverage(self):
        fixture = json.loads((Path(__file__).parent/'testdata/icebox_false_floor_intersection.json').read_bytes())
        first, second = [shapely.from_geojson(json.dumps(fixture[key])) for key in ['first', 'second']]
        point = shapely.Point(fixture['point'])
        self.assertTrue(first.covers(point))
        self.assertGreater(second.distance(point), .4)
        result, _ = reconcile_supports(dict(supports=[]),
            [(dict(id='upper-floor'), first, np.array(fixture['firstPlane']))],
            [(second, np.array(fixture['secondPlane']))], first.envelope.buffer(1))
        self.assertEqual(len(result), 1)
        self.assertTrue(polygon(result[0]).covers(point))
        self.assertLess(polygon(result[0]).difference(first.buffer(1e-8)).area, 1e-8)

    def test_existing_physical_container_floor_keeps_its_interior_name(self):
        shape = shapely.box(0, 0, 3, 3)
        old = dict(id='icebox-a-stacked-b-interior-floor', label='A Site Nest interior',
            rings=[[0, 0, 3, 0, 3, 3, 0, 3]], fillRule='evenodd',
            automaticStandingAllowed=True, surfaceElevationMeters=5.69857788)
        physical = dict(old, id='physical-collider', label='Platform', surfaceElevationMeters=5.75)
        source = dict(id='volume-344-0', sourceCollision='/Port_BVPawn/BP_BlockingVolume73/Cube#0')
        result, evidence = reconcile_supports(dict(supports=[old, physical]),
            [(source, shape, np.array([0., 0., 5.75]))], [], shape)
        self.assertEqual(result, [dict(physical, label=old['label'])])
        self.assertEqual(evidence['existing'][1]['labelSourceSupportId'], old['id'])
        self.assertEqual(evidence['added'], [])
        with self.assertRaises(AssertionError):
            verify_supports([old, physical], result, shape)
        verify_supports([old, physical], result, shape, {physical['id']: old['id']})

    def test_measured_player_collider_keeps_the_reviewed_pipe_name(self):
        shape = shapely.box(0, 0, 3, 3)
        old = dict(id='icebox-a-boost-pipes-low-step', label='A Site lower pipe step',
            rings=[[0, 0, 3, 0, 3, 3, 0, 3]], fillRule='evenodd',
            automaticStandingAllowed=True, surfaceElevationMeters=5.497576)
        source = dict(id='volume-695-0', sourceCollision='/Port_BVPawn/BP_BlockingVolume134/Cube#0')
        result, evidence = reconcile_supports(dict(supports=[old]),
            [(source, shape, np.array([0., 0., 5.5021]))], [], shape)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]['label'], old['label'])
        self.assertEqual(result[0]['surfaceElevationMeters'], 5.5021)
        self.assertEqual(evidence['added'][0]['labelSourceSupportId'], old['id'])

    def test_source_rounding_keeps_the_named_pipe_choice(self):
        shape = shapely.box(0, 0, 3, 3)
        support = dict(id='pipe-step', label='Lower pipe', rings=[[0, 0, 3, 0, 3, 3, 0, 3]],
            fillRule='evenodd', automaticStandingAllowed=True, surfaceElevationMeters=5.497431)
        result, _ = reconcile_supports(dict(supports=[support]),
            [(dict(id='source-pipe'), shape, np.array([0., 0., 5.4974]))], [], shape)
        self.assertEqual(result, [support])

    def test_close_source_levels_remain_explicit_choices(self):
        shape = shapely.box(0, 0, 3, 3)
        low = np.array([0., 0., 1.461481])
        middle = np.array([0., 0., 1.465011])
        upper = np.array([0., 0., 1.491374])
        source = [(dict(id=name), shape, plane) for name, plane in
                  [('low', low), ('middle', middle), ('upper', upper)]]
        result, _ = reconcile_supports(dict(supports=[]), source, [(shape, low)], shape)
        self.assertEqual([s['id'] for s in result], ['icebox-measured-middle', 'icebox-measured-upper'])
        self.assertEqual([s['surfaceElevationMeters'] for s in result], [middle[2], upper[2]])

    def test_parent_verification_rejects_wrong_height_and_missing_area(self):
        ground = dict(vertices=[200, 200, 1, 210, 200, 2, 200, 210, 3], triangles=[0, 1, 2])
        domains = [(shapely.box(201, 201, 202, 202), np.array([0., 0., 7.]))]
        parents = []
        result, _ = replace_ground(ground, domains, mark_standing=True, triangle_parents=parents)
        verify_ground(ground, result, domains, parents)
        wrong_height = copy.deepcopy(result)
        wrong_height['vertices'][wrong_height['triangles'][0]*3+2] += .1
        with self.assertRaises(AssertionError):
            verify_ground(ground, wrong_height, domains, parents)
        missing = copy.deepcopy(result)
        missing['triangles'] = missing['triangles'][:-3]
        missing['standingTriangles'] = missing['standingTriangles'][:-1]
        with self.assertRaises(AssertionError):
            verify_ground(ground, missing, domains, parents[:-1])

    def test_measured_dip_clips_old_flat_support_and_retains_upper_level(self):
        model = dict(supports=[dict(id='saved-flat', rings=[[0, 0, 4, 0, 4, 4, 0, 4]],
            fillRule='evenodd', automaticStandingAllowed=True, surfaceElevationMeters=1)])
        region = shapely.box(1, 1, 3, 3)
        lower = np.array([0., 0., .8])
        upper_shape = shapely.box(2, 1, 3, 3)
        source = [(dict(id='dip'), region, lower),
                  (dict(id='upper'), upper_shape, np.array([0., 0., 2.]))]
        result, evidence = reconcile_supports(model, source, [(region, lower)], region)
        self.assertEqual(result[0]['id'], 'saved-flat')
        self.assertAlmostEqual(polygon(result[0]).area, 12)
        self.assertFalse(polygon(result[0]).covers(shapely.Point(1.5, 2)))
        self.assertEqual(result[1]['id'], 'icebox-measured-upper')
        self.assertAlmostEqual(polygon(result[1]).symmetric_difference(upper_shape).area, 0)
        self.assertEqual(evidence['existing'][0]['removedAreaSvg'], 4)

    def test_crossing_floors_choose_lower_plane_on_each_side(self):
        shape = shapely.box(0, 0, 4, 4)
        domains = lowest_domains([(shape, np.array([1., 0., 0.])),
                                  (shape, np.array([-1., 0., 4.]))])
        self.assertAlmostEqual(domains[0][0].area, 8, places=5)
        self.assertAlmostEqual(domains[1][0].area, 8, places=5)
        self.assertTrue(domains[0][0].covers(shapely.Point(1, 2)))
        self.assertFalse(domains[0][0].covers(shapely.Point(3, 2)))
        self.assertTrue(domains[1][0].covers(shapely.Point(3, 2)))

    def test_patch_hole_keeps_old_height_and_physical_flags(self):
        ground = dict(vertices=[0, 0, 7, 10, 0, 7, 10, 10, 7, 0, 10, 7],
                      triangles=[0, 1, 2, 0, 2, 3], standingTriangles=[0])
        ring = shapely.box(2, 2, 8, 8).difference(shapely.box(4, 4, 6, 6))
        overlapping = shapely.box(3, 3, 7, 7).difference(shapely.box(4, 4, 6, 6))
        result, count = replace_ground(ground, [(ring, np.array([.1, 0, 2.])),
            (overlapping, np.array([0., 0, 20.]))], mark_standing=True)
        self.assertEqual(count, 2)
        vertices = np.array(result['vertices']).reshape(-1, 3)
        triangles = vertices[np.array(result['triangles']).reshape(-1, 3)]
        shapes = shapely.polygons(triangles[:, :, :2])
        self.assertAlmostEqual(shapely.union_all(shapes).area, 100)
        self.assertAlmostEqual(sum(s.area for s in shapes), 100)
        for i, (triangle, shape) in enumerate(zip(triangles, shapes)):
            point = shape.representative_point()
            if ring.covers(point):
                self.assertIn(i, result['standingTriangles'])
                np.testing.assert_allclose(triangle[:, 2], .1 * triangle[:, 0] + 2)
            else:
                np.testing.assert_allclose(triangle[:, 2], 7)
                self.assertEqual(i in result['standingTriangles'], point.x > point.y)


if __name__ == '__main__':
    unittest.main()
