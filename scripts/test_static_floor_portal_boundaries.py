"""Portal cuts need their own states, including candidates absent on both sides."""
import unittest

import numpy as np

import static_floor_portal as portal


class PortalBoundaryTests(unittest.TestCase):
    def test_three_plane_knot_has_a_candidate_missing_from_both_open_sides(self):
        endpoints = np.array([[0., 0.], [1., 0.]])
        previous = np.zeros(3)
        planes = np.array([[0., 0., .25], [1., 0., -.25], [-1., 0., .75]])
        table = portal.compile_portal_table(endpoints, previous, planes, planes)
        # At exactly .5 all navigation heights tie. Hint zero selects the flat
        # source by gradient; just left/right the other navigation plane wins.
        for t, expected in [(np.nextafter(.5, 0.), [1]),
                            (.5, [0]),
                            (np.nextafter(.5, 1.), [2])]:
            self.assertEqual(portal.choose([t, 0.], previous, planes, planes), expected)
            self.assertEqual(portal.lookup_portal(table, t), expected)
        for t in (0., 1.):
            self.assertEqual(portal.lookup_portal(table, t), [0])

    def test_tie_band_and_native_step_cut_neighbors_match_pointwise_policy(self):
        endpoints = np.array([[0., 0.], [1., 0.]])
        previous = np.zeros(3)
        cases = [
            (np.array([[0., 0., 0.], [1., 0., -.5]]), [], {}),
            (np.array([[0., 0., 0.], [.2, 0., .25]]), [[0., 0., 0.]],
             dict(terrain=[False, True])),
            (np.array([[0., 0., 0.], [.00004, 0., -.00002]]), [],
             dict(raised=[True, True], raised_origin=True)),
        ]
        for sources, nav, options in cases:
            table = portal.compile_portal_table(endpoints, previous, sources, nav, **options)
            intervals = portal.compile_portal(endpoints, previous, sources, nav, **options)
            cuts = {0., 1.} | {row[key] for row in intervals for key in ('lo', 'hi')}
            # Merged interval interiors can still contain an exceptional knot.
            cuts.update(knot['at'] for knot in table['knots'])
            for cut in cuts:
                for t in (cut, np.nextafter(cut, -np.inf), np.nextafter(cut, np.inf)):
                    if not 0 <= t <= 1:
                        continue
                    expected = portal.choose([t, 0.], previous, sources, nav, **options)
                    self.assertEqual(portal.lookup_portal(table, t), expected,
                                     (options, cut, t, expected))


if __name__ == '__main__':
    unittest.main()
