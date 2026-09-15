import unittest

import numpy as np
import shapely

from world_visibility_reduce import navigation_domain, reduce_segments, visible_region, visible_segment_indices


def rectangle(x0, y0, x1, y1):
    points = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
    return list(zip(points, points[1:] + points[:1]))


class VisibilityReductionTests(unittest.TestCase):
    def test_prop_interior_diagonals_removed_but_entire_room_and_prop_outline_kept(self):
        outline = rectangle(0, 0, 10, 10) + rectangle(4, 4, 6, 6)
        hidden = [((4, 4), (6, 6)), ((4, 6), (6, 4))]
        result, summary = reduce_segments(outline + hidden, shapely.box(1, 1, 2, 2))
        self.assertEqual(result, outline)
        self.assertEqual(summary['removedSegments'], 2)

    def test_open_chain_inside_observer_face_is_kept(self):
        lines = rectangle(0, 0, 10, 10) + [((4, 4), (6, 6))]
        result, _ = reduce_segments(lines, shapely.box(1, 1, 2, 2))
        self.assertEqual(result, lines)

    def test_narrow_opening_does_not_become_a_closed_room(self):
        gap = 1e-8
        walls = [((0, 0), (10, 0)), ((10, 0), (10, 10)), ((10, 10), (0, 10)),
                 ((0, 10), (0, 5 + gap)), ((0, 5 - gap), (0, 0)), ((4, 4), (6, 6))]
        result, _ = reduce_segments(walls, shapely.box(-2, 4, -1, 6))
        self.assertEqual(result, walls)

    def test_unbounded_observer_face_keeps_open_lines_and_prop_front(self):
        outlines = rectangle(4, 4, 6, 6) + [((9, 2), (9, 9))]
        result, _ = reduce_segments(outlines + [((4, 4), (6, 6))], shapely.box(0, 0, 1, 1))
        self.assertEqual(result, outlines)

    def test_observer_domain_touching_prop_selects_incident_interior_face(self):
        lines = rectangle(0, 0, 10, 10) + rectangle(4, 4, 6, 6) + [((4, 4), (6, 6))]
        result, _ = reduce_segments(lines, shapely.box(2, 2, 4, 4))
        self.assertEqual(result, lines)

    def test_segment_crossing_hidden_and_visible_faces_is_retained_in_full(self):
        lines = rectangle(0, 0, 10, 10) + rectangle(4, 4, 6, 6) + [((3.9, 5), (6.5, 5))]
        result, _ = reduce_segments(lines, shapely.box(1, 1, 2, 2))
        self.assertEqual(result, lines)

    def test_all_floor_observer_polygons_are_included(self):
        nav = {'coordinateScale': 10, 'vertices': [10, 10, 0, 20, 10, 0, 10, 20, 0,
                                                  110, 10, 900, 120, 10, 900, 110, 20, 900],
               'polygons': [[0, 1, 2], [3, 4, 5]], 'walkable': [True, True]}
        domain = navigation_domain(nav, 1)
        lines = rectangle(0, 0, 5, 5) + rectangle(10, 0, 15, 5)
        result, _ = reduce_segments(lines, domain)
        self.assertEqual(result, lines)

    def test_invalid_domain_and_zero_length_geometry_raise(self):
        with self.assertRaises(ValueError):
            reduce_segments(rectangle(0, 0, 5, 5), shapely.Point(1, 1))
        with self.assertRaises(ValueError):
            reduce_segments([((1, 1), (1, 1))], shapely.box(0, 0, 5, 5))

    def test_returned_endpoints_are_original_objects(self):
        lines = np.asarray(rectangle(0, 0, 5, 5), dtype=np.int64)
        result, _ = reduce_segments(lines, shapely.box(1, 1, 2, 2))
        np.testing.assert_array_equal(result, lines)
        self.assertTrue(all(row.dtype == np.int64 for row in result))

    def test_pre_alpha_cull_removes_only_segments_behind_solid_closed_boundaries(self):
        solids = rectangle(4, 4, 6, 6)
        candidates = [((4.2, 4.2), (5.8, 5.8)), ((20, 0), (20, 10))]
        region, summary = visible_region(solids, shapely.box(0, 0, 1, 1), candidate_bounds=(4.2, 0, 20, 10))
        self.assertEqual(visible_segment_indices(candidates, region).tolist(), [1])
        self.assertGreater(summary['enclosingBounds'][2], 20)

    def test_no_solid_blockers_keeps_distant_alpha_candidates(self):
        candidates = [((20, 0), (20, 10))]
        region, _ = visible_region([], shapely.box(0, 0, 1, 1), candidate_bounds=(20, 0, 20, 10))
        self.assertEqual(visible_segment_indices(candidates, region).tolist(), [0])


if __name__ == '__main__':
    unittest.main()
