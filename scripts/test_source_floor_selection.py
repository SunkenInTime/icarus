"""Analytic floor selection regressions, independent of game extraction."""
import unittest
import numpy as np
import shapely
from probe_source_floor_support import SourceSupport
from probe_tactical_floor_selection_counterexample import RampAndWall


def rectangles(rows):
    result = []
    for x0, x1, slope, intercept in rows:
        xy = np.array([[x0, 0], [x1, 0], [x1, 2], [x0, 2]], dtype=float)
        xyz = np.c_[xy, xy[:, 0] * slope + intercept]
        result.extend([xyz[[0, 1, 2]], xyz[[0, 2, 3]]])
    return np.array(result)


def model(source_rows, nav_rows):
    source = rectangles(source_rows)
    nav = rectangles(nav_rows)
    support = SourceSupport.__new__(SourceSupport)
    support.points = np.concatenate([source, nav])
    support.source_ids = np.r_[np.arange(len(source)), -1 - np.arange(len(nav))]
    support.objects = ['source floor'] * len(source) + ['navigation'] * len(nav)
    support.navigation_indices = np.arange(len(source), len(support.points))
    support.detailed_navigation_indices = support.navigation_indices
    support.planes = np.linalg.solve(np.concatenate([support.points[:, :, :2],
        np.ones((len(support.points), 3, 1))], axis=2), support.points[:, :, 2, None])[:, :, 0]
    support.polygons = shapely.polygons(support.points[:, :, :2])
    support.tree = shapely.STRtree(support.polygons)
    return support


class Walls:
    def __init__(self, walls):
        self.walls = walls

    def cast(self, start, end, min_distance=1e-5, end_padding=1e-5):
        start, end = np.array(start), np.array(end)
        delta = end - start
        length = np.linalg.norm(delta)
        if abs(delta[0]) < 1e-12:
            return None
        hits = []
        for x, lower, upper, label in self.walls:
            t = (x - start[0]) / delta[0]
            distance = t * length
            point = start + t * delta
            if distance >= min_distance and distance <= length - end_padding and lower <= point[2] <= upper:
                hits.append(dict(point=point.tolist(), object=label, distanceMeters=float(distance)))
        return min(hits, key=lambda hit: hit['distanceMeters']) if hits else None


class SelectionTests(unittest.TestCase):
    def cast(self, support, source, origin, direction=(1, 0), distance=8):
        return support.cast(source, origin, direction, distance, allow_floor_transitions=True,
                            navigation_guided=True, constant_standing_height=True, maximum_step_height=.35, lock_after_gap=True)

    def test_uphill_buried_base_reaches_far_wall(self):
        support = model([(-2, 6, 0, 0), (0, 4, .5, 0), (4, 6, 0, 2)],
                        [(-2, 0, 0, 0), (0, 4, .5, 0), (4, 6, 0, 2)])
        result = self.cast(support, RampAndWall(), [-1, 1, 1.75])
        self.assertEqual(result['hit']['object'], 'wall')
        self.assertAlmostEqual(result['distanceMeters'], 7)

    def test_subnanometre_floor_event_gap_cannot_omit_wall(self):
        floors=[(-2,2,0,0),(2+2e-11,8,0,0)]
        support=model(floors,floors)
        wall_x=2+1e-11
        result=self.cast(support,Walls([(wall_x,0,8,'seam wall')]),[-1,1,1.75])
        self.assertIsNotNone(result['hit'])
        self.assertAlmostEqual(result['distanceMeters'],wall_x+1,places=12)

    def test_underpass_preserves_lower_layer(self):
        support = model([(-2, 8, 0, 0), (0, 8, 0, 3)],
                        [(-2, 8, 0, 0), (0, 8, 0, 3)])
        result = self.cast(support, Walls([(4, 3, 5, 'upper wall'), (6, 0, 2, 'lower wall')]), [-1, 1, 1.75])
        self.assertEqual(result['hit']['object'], 'lower wall')
        self.assertAlmostEqual(result['distanceMeters'], 7)
        self.assertTrue(all(max(piece['ground']) == 0 for piece in result['pieces']))

    def test_overpass_preserves_upper_layer(self):
        support = model([(-2, 8, 0, 0), (0, 8, 0, 3)],
                        [(-2, 8, 0, 0), (0, 8, 0, 3)])
        result = self.cast(support, Walls([(4, 3, 5, 'upper wall'), (6, 0, 2, 'lower wall')]), [1, 1, 4.75])
        self.assertEqual(result['hit']['object'], 'upper wall')
        self.assertAlmostEqual(result['distanceMeters'], 3)

    def test_inset_lower_nav_end_does_not_pull_ray_upstairs(self):
        support = model([(-2, 8, 0, 0), (0, 8, 0, 3)],
                        [(-2, 2, 0, 0), (0, 8, 0, 3)])
        result = self.cast(support, Walls([(4, 3, 5, 'upper wall'), (6, 0, 2, 'lower wall')]), [-1, 1, 1.75])
        self.assertEqual(result['hit']['object'], 'lower wall')
        self.assertAlmostEqual(result['distanceMeters'], 7)

    def test_inset_upper_nav_end_does_not_pull_ray_downstairs(self):
        support = model([(-2, 8, 0, 0), (0, 8, 0, 3)],
                        [(-2, 8, 0, 0), (0, 2, 0, 3)])
        result = self.cast(support, Walls([(4, 3, 5, 'upper wall'), (6, 0, 2, 'lower wall')]), [1, 1, 4.75])
        self.assertEqual(result['hit']['object'], 'upper wall')
        self.assertAlmostEqual(result['distanceMeters'], 3)

    def test_standing_height_does_not_inherit_nav_tread_offset(self):
        support = model([(-2, 8, 0, 0)], [(-2, 8, 0, .2)])
        result = self.cast(support, Walls([(3, 1.8, 2.1, 'above head'), (6, 0, 3, 'wall')]), [-1, 1, 1.95])
        self.assertEqual(result['hit']['object'], 'wall')
        self.assertAlmostEqual(result['distanceMeters'], 7)

    def test_nearby_prop_does_not_raise_a_nav_matched_floor(self):
        support = model([(-2, 8, 0, 0), (0, 8, 0, .3)], [(-2, 8, 0, 0)])
        result = self.cast(support, Walls([(3, 0, 2, 'two metre wall')]), [-1, 1, 1.75])
        self.assertEqual(result['hit']['object'], 'two metre wall')
        self.assertAlmostEqual(result['distanceMeters'], 4)
        self.assertTrue(all(max(piece['ground']) == 0 for piece in result['pieces']))

    def test_real_tall_wall_before_ramp_still_blocks(self):
        support = model([(-2, 6, 0, 0), (0, 4, .5, 0), (4, 6, 0, 2)],
                        [(-2, 0, 0, 0), (0, 4, .5, 0), (4, 6, 0, 2)])
        result = self.cast(support, Walls([(1, 0, 4, 'wall')]), [-1, 1, 1.75])
        self.assertEqual(result['hit']['object'], 'wall')
        self.assertAlmostEqual(result['distanceMeters'], 2)

    def test_reverse_ramp_follows_same_ground(self):
        support = model([(-2, 6, 0, 0), (0, 4, .5, 0), (4, 6, 0, 2)],
                        [(-2, 0, 0, 0), (0, 4, .5, 0), (4, 6, 0, 2)])
        result = self.cast(support, Walls([(-1, 0, 3, 'lower wall')]), [5, 1, 3.75], direction=(-1, 0))
        self.assertEqual(result['hit']['object'], 'lower wall')
        self.assertAlmostEqual(result['distanceMeters'], 6)
        for piece in result['pieces']:
            for distance, height in zip([piece['start'], piece['end']], piece['ground']):
                self.assertAlmostEqual(height, np.clip((5 - distance) / 2, 0, 2))

    def test_upward_step_within_native_climb_follows_surface(self):
        support = model([(-2, 0, 0, 0), (0, 8, 0, .25)],
                        [(-2, 0, 0, 0), (0, 8, 0, .25)])
        result = self.cast(support, Walls([(0, 0, .25, 'step front'), (6, .25, 3, 'wall')]), [-1, 1, 1.75])
        self.assertEqual(result['hit']['object'], 'wall')
        self.assertAlmostEqual(result['distanceMeters'], 7)
        self.assertAlmostEqual(result['pieces'][-1]['ground'][-1], .25)

    def test_abrupt_ledge_does_not_lower_eye_to_destination_floor(self):
        support = model([(-2, 0, 0, 3), (0, 8, 0, 0)],
                        [(-2, 0, 0, 3), (0, 8, 0, 0)])
        result = self.cast(support, Walls([(3, 0, 2, 'lower crate'), (6, 0, 6, 'wall')]), [-1, 1, 4.75])
        self.assertEqual(result['hit']['object'], 'wall')
        self.assertAlmostEqual(result['distanceMeters'], 7)
        self.assertTrue(all(max(piece['ground']) == 3 for piece in result['pieces']))

    def test_air_gap_keeps_height_when_lower_floor_returns(self):
        support = model([(-2, 0, 0, 3), (2, 8, 0, 0)],
                        [(-2, 0, 0, 3), (2, 8, 0, 0)])
        result = self.cast(support, Walls([(3, 0, 2, 'lower crate'), (6, 0, 6, 'wall')]), [-1, 1, 4.75])
        self.assertEqual(result['hit']['object'], 'wall')
        self.assertAlmostEqual(result['distanceMeters'], 7)
        self.assertTrue(any(piece['candidateCount'] == 0 for piece in result['pieces']))
        self.assertTrue(all(max(piece['ground']) == 3 for piece in result['pieces']))

    def test_vertical_cliff_cannot_be_skipped_by_jumping_up(self):
        support = model([(-2, 0, 0, 0), (0, 8, 0, 3)],
                        [(-2, 0, 0, 0), (0, 8, 0, 3)])
        result = self.cast(support, Walls([(0, 0, 3, 'cliff')]), [-1, 1, 1.75])
        self.assertEqual(result['hit']['object'], 'cliff')
        self.assertAlmostEqual(result['distanceMeters'], 1)

    def test_remote_approaching_floor_does_not_reattach_after_gap(self):
        # The remote slope passes through the former 35 cm reattachment
        # threshold. Both neighboring observers must retain their own eye.
        support = model([(-2, 0, 0, 3), (2, 8, .1, 2.1)],
                        [(-2, 0, 0, 3), (2, 8, .1, 2.1)])
        for x in [-1.01, -1, -.99]:
            result = self.cast(support, Walls([(6, 0, 6, 'wall')]), [x, 1, 4.75])
            self.assertAlmostEqual(result['distanceMeters'], 6 - x)
            self.assertTrue(all(max(piece['ground']) == 3 for piece in result['pieces']))
            self.assertEqual(result['pieces'][-1]['supportState'], 'detached')

    def test_fifty_micrometre_seam_does_not_detach_from_ramp(self):
        support = model([(-2, 0, 0, 0), (.00005, 4, .5, 0), (4, 8, 0, 2)],
                        [(-2, 0, 0, 0), (.00005, 4, .5, 0), (4, 8, 0, 2)])
        result = self.cast(support, RampAndWall(), [-1, 1, 1.75])
        self.assertEqual(result['hit']['object'], 'wall')
        self.assertAlmostEqual(result['distanceMeters'], 7)
        self.assertFalse(any(piece['supportState'] == 'detached' for piece in result['pieces']))

    def test_source_step_not_interpolated_nav_hint_controls_climb(self):
        for hint in [.34816, .35025]:
            support = model([(-2, 8, 0, 0), (0, 8, 0, .2449)],
                            [(-2, 0, 0, 0), (0, 8, 0, hint)])
            result = self.cast(support, Walls([(6, .2449, 3, 'wall')]), [-1, 1, 1.75])
            self.assertEqual(result['hit']['object'], 'wall')
            self.assertAlmostEqual(result['distanceMeters'], 7)
            self.assertAlmostEqual(result['pieces'][-1]['ground'][-1], .2449)
            self.assertFalse(any(piece['supportState'] == 'detached' for piece in result['pieces']))

    def test_explicit_prop_top_origin_keeps_height_after_its_edge(self):
        support = model([(-2, 8, 0, 0), (0, 2, 0, 2.5)],
                        [(-2, 8, 0, 0), (0, 2, 0, 2.5)])
        result = self.cast(support, Walls([(4, 0, 2, 'low crate'), (6, 0, 6, 'wall')]), [1, 1, 4.25])
        self.assertEqual(result['hit']['object'], 'wall')
        self.assertAlmostEqual(result['distanceMeters'], 5)
        self.assertTrue(all(max(piece['ground']) == 2.5 for piece in result['pieces']))

    def test_real_nav_prop_top_does_not_raise_continuing_lower_ray(self):
        support = model([(-2, 8, 0, 0), (0, 8, 0, .3)],
                        [(-2, 8, 0, 0), (0, 8, 0, .3)])
        result = self.cast(support, Walls([(6, 0, 2, 'two metre wall')]), [-1, 1, 1.75])
        self.assertEqual(result['hit']['object'], 'two metre wall')
        self.assertAlmostEqual(result['distanceMeters'], 7)
        self.assertTrue(all(max(piece['ground']) == 0 for piece in result['pieces']))

    def test_audited_terrain_tread_replaces_buried_base(self):
        support = model([(-2, 8, 0, 0), (0, 1, 0, .2449), (1, 8, 0, .4962)],
                        [(-2, .5, 0, 0), (.5, 8, 0, .5)])
        result = support.cast(Walls([(6, .4962, 3, 'wall')]), [-1, 1, 1.75], [1, 0], 8,
                              True, True, True, .35, True, terrain_source_faces=range(2, 6))
        self.assertEqual(result['hit']['object'], 'wall')
        self.assertAlmostEqual(result['pieces'][-1]['ground'][-1], .4962)

    def test_nav_cannot_invent_intermediate_step(self):
        support = model([(-2, 0, 0, 0), (1, 8, 0, .5)],
                        [(-2, 0, 0, 0), (0, 1, 0, .3), (1, 8, 0, .5)])
        result = self.cast(support, Walls([(6, 0, 2, 'wall')]), [-1, 1, 1.75])
        self.assertAlmostEqual(result['distanceMeters'], 7)
        self.assertTrue(all(max(piece['ground']) == 0 for piece in result['pieces']))
        self.assertTrue(all(piece['sourceFace'] is None or piece['sourceFace'] >= 0 for piece in result['pieces']))

    def test_audited_prop_with_no_underlying_floor_keeps_incoming_eye(self):
        support = model([(-2, 0, 0, 0), (0, 2, 0, .3), (2, 8, 0, 0)],
                        [(-2, 0, 0, 0), (0, 2, 0, .3), (2, 8, 0, 0)])
        result = support.cast(Walls([(6, 0, 2, 'wall')]), [-1, 1, 1.75], [1, 0], 8,
                              True, True, True, .35, True, raised_source_faces=[2, 3])
        self.assertAlmostEqual(result['distanceMeters'], 7)
        self.assertTrue(all(max(piece['ground']) == 0 for piece in result['pieces']))

    def test_audited_prop_is_valid_standing_origin(self):
        support = model([(-2, 0, 0, 0), (0, 2, 0, .3), (2, 8, 0, 0)],
                        [(-2, 0, 0, 0), (0, 2, 0, .3), (2, 8, 0, 0)])
        result = support.cast(Walls([(6, 0, 3, 'wall')]), [.25, 1, 2.05], [1, 0], 8,
                              True, True, True, .35, True, raised_source_faces=[2, 3])
        self.assertAlmostEqual(result['distanceMeters'], 5.75)
        self.assertTrue(any(piece['sourceFace'] in [2, 3] for piece in result['pieces']))
        self.assertTrue(all(abs(max(piece['ground']) - .3) < 1e-10 for piece in result['pieces']))

    def test_original_shared_floor_edge_wins_over_buffer_and_irrelevant_edge(self):
        for unrelated in [False, True]:
            nav = [(-2, 8, .0005, 0)]
            if unrelated:
                nav.append((-.004, .02, 0, 100))
            support = model([(-2, 0, .001, 0), (0, 8, 0, 0)], nav)
            support.original_polygons = support.polygons.copy()
            source = support.source_ids >= 0
            support.polygons[source] = shapely.buffer(support.polygons[source], .03)
            support.tree = shapely.STRtree(support.polygons)
            result = self.cast(support, Walls([(2, -1, 3, 'wall')]), [-1, 1, 1.749], distance=4)
            for piece in result['pieces']:
                for distance, height in zip([piece['start'], piece['end']], piece['ground']):
                    self.assertAlmostEqual(height, min(distance - 1, 0) * .001, places=11)
            self.assertTrue(any(abs(piece['start'] - 1) < 1e-10 for piece in result['pieces']))


if __name__ == '__main__':
    unittest.main()
