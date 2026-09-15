"""Regression checks for source sections and the assumed-height review loophole."""
import unittest
import json
from pathlib import Path
import tempfile
import numpy as np

from audit_assumed_svg_height_sections import clipped_height_intervals, merge_intervals
from compile_reviewed_svg_height_map import height_record
from review_icebox_nest_ends import find_drawn_ends, closed_bands
from install_all_map_gameplay_revision import require_resolved_heights
from audit_assumed_svg_sightlines import reviewed_annotation_ids


def wall(wid, points):
    return dict(id=wid, rings=[np.asarray(points).reshape(-1).tolist()], fillRule='evenodd')


class ReviewAcceptanceTest(unittest.TestCase):
    def test_installer_rejects_intervals_that_runtime_cannot_load(self):
        for bands in [[[0, 0]], [[4, 3]], [[float('nan'), 3]]]:
            with self.assertRaisesRegex(ValueError, 'Invalid runtime height'):
                require_resolved_heights(dict(walls=[dict(id='wall',
                    unknownHeight=False, bands=bands)]))

    def test_only_explicit_gameplay_annotations_can_omit_wall_probes(self):
        model = dict(walls=[dict(id='zipline', bands=[], unknownHeight=False),
                            dict(id='wall', bands=[[0, 4]], unknownHeight=False)])
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.assertEqual(reviewed_annotation_ids(directory, model), set())
            rows = [dict(wallId=wid, bandsAboveSourceZero=[],
                         gameplaySource='https://playvalorant.com/map-review')
                    for wid in ['zipline', 'wall']]
            path = directory / 'specific-height-review.json'
            path.write_text(json.dumps(dict(records=rows)))
            self.assertEqual(reviewed_annotation_ids(directory, model), {'zipline'})
            del rows[0]['gameplaySource']
            path.write_text(json.dumps(dict(records=rows)))
            self.assertEqual(reviewed_annotation_ids(directory, model), set())

    def test_installer_rejects_assumptions_even_with_a_reviewed_label(self):
        for unknown, bands in [(False, [[0, None]]), (False, [[0, float('inf')]]),
                               (True, [[0, 4]])]:
            with self.assertRaisesRegex(ValueError, 'assumed wall heights'):
                require_resolved_heights(dict(walls=[dict(id='wall',
                    reviewStatus='reviewed', unknownHeight=unknown, bands=bands)]))
        require_resolved_heights(dict(walls=[dict(id='window',
            unknownHeight=False, bands=[[0, 5.7], [8.8, 15.5]])]))

    def test_reviewed_label_cannot_accept_an_infinite_structure(self):
        original = wall('end', [[0, 0], [.5, 0], [.5, 4], [0, 4]])
        decision = dict(reviewStatus='reviewed', mode='solid',
                        floorElevationMeters=2, remainingUncertainties=[])
        with self.assertRaisesRegex(ValueError, 'Assumed structural height'):
            height_record(original, decision, False)
        self.assertTrue(height_record(original, decision, True)['unknownHeight'])

    def test_infinite_band_cannot_bypass_the_structural_check(self):
        original = wall('end', [[0, 0], [.5, 0], [.5, 4], [0, 4]])
        decision = dict(reviewStatus='reviewed', mode='source-height',
                        floorElevationMeters=0, bandsAboveFloor=[[0, None]])
        with self.assertRaisesRegex(ValueError, 'Assumed structural height'):
            height_record(original, decision, False)

    def test_nonfinite_source_maximum_cannot_bypass_the_structural_check(self):
        original = wall('end', [[0, 0], [.5, 0], [.5, 4], [0, 4]])
        for top in [None, float('inf'), float('nan')]:
            with self.assertRaisesRegex(ValueError, 'Assumed structural height'):
                height_record(original, dict(reviewStatus='reviewed', mode='source-height',
                    floorElevationMeters=0, maximumSourceZ=top), False)

    def test_finite_window_retains_its_open_band(self):
        original = wall('end', [[0, 0], [.5, 0], [.5, 4], [0, 4]])
        decision = dict(reviewStatus='reviewed', mode='source-height',
                        floorElevationMeters=0,
                        bandsAboveFloor=[[0, 5.7], [8.8, 15.5]])
        result = height_record(original, decision, False)
        self.assertFalse(result['unknownHeight'])
        self.assertFalse(any(lo <= 7.45 <= hi for lo, hi in result['bands']))
        self.assertTrue(any(lo <= 2.75 <= hi for lo, hi in result['bands']))

    def test_opposite_end_inside_a_long_path_is_not_omitted(self):
        walls = [
            wall('left', [[0, 0], [.5, 0], [.5, 4], [0, 4]]),
            wall('long-right', [[10, 0], [10.5, 0], [10.5, 9], [10, 9]]),
        ]
        ends = find_drawn_ends(walls, [[.2, .2], [10.2, 3.8]])
        self.assertEqual([e['wallId'] for e in ends], ['left', 'long-right'])
        self.assertEqual(ends[1]['along'], ends[0]['along'])

    def test_missing_opposite_end_is_an_error(self):
        with self.assertRaisesRegex(ValueError, 'Missing drawn Nest end'):
            find_drawn_ends([wall('left', [[0, 0], [.5, 0], [.5, 4], [0, 4]])],
                            [[.2, .2], [10.2, 3.8]])

    def test_clipped_slope_includes_rectangle_corners_inside_the_triangle(self):
        xy = np.array([[-10., -10.], [10., -10.], [0., 10.]])
        tri = np.c_[xy, xy @ np.array([2., 3.]) + 4.][None]
        ids, intervals = clipped_height_intervals(tri, np.array([0., 0.]),
                                                  np.array([1., 0.]), .15, .6)
        self.assertEqual(ids.tolist(), [0])
        np.testing.assert_allclose(intervals, [[1.9, 6.1]], atol=1e-10)

    def test_section_clipping_is_rotation_invariant(self):
        tri = np.array([[[-2., 0., 1.], [2., 0., 1.], [2., 0., 5.]]])
        _, expected = clipped_height_intervals(tri, np.zeros(2), np.array([1., 0.]), .15, .6)
        angle = .71
        rotation = np.array([[np.cos(angle), -np.sin(angle)],
                             [np.sin(angle), np.cos(angle)]])
        rotated = tri.copy()
        rotated[:, :, :2] = tri[:, :, :2] @ rotation.T + [5., 7.]
        _, actual = clipped_height_intervals(rotated, np.array([5., 7.]),
                                             rotation @ [1., 0.], .15, .6)
        np.testing.assert_allclose(actual, expected, atol=1e-10)

    def test_interval_union_does_not_fill_a_window(self):
        self.assertEqual(merge_intervals(np.array([[0, 3], [0, 1], [5, 8], [6, 9]])),
                         [[0., 3.], [5., 9.]])
        self.assertEqual(closed_bands([[0, 3], [3.02, 5.7], [8.8, 12]]),
                         [[0., 5.7], [8.8, 12.]])


if __name__ == '__main__':
    unittest.main()
