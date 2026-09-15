"""A physical ray's displayed path must not be replaced by a straight SVG ray."""
import unittest

import numpy as np
import shapely

from probe_normalized_wall_junctions import inverse_wall_lines
from tactical_alignment_composite import explicit_warp


class JunctionCoordinateTests(unittest.TestCase):
    def test_piecewise_shear_preserves_intended_physical_contact(self):
        # Independent analytic map: W(x,y)=(x,y+.6*max(x-1,0)). The inverse
        # image of displayed y=0 bends at native x=1.
        source = np.array([[0., -3.], [1., -3.], [3., -3.],
                           [0., 3.], [1., 3.], [3., 3.]])
        target = source.copy()
        target[:, 1] += .6 * np.maximum(source[:, 0] - 1, 0)
        cells = np.array([[0, 1, 4], [0, 4, 3], [1, 2, 5], [1, 5, 4]])
        backward = explicit_warp(target, source - target, cells)
        walls = inverse_wall_lines([shapely.LineString([[.5, 0], [2.5, 0]])],
                                   shapely.polygons(target[cells]), backward,
                                   np.eye(2), np.zeros(2))
        start = np.array([0., 2.])
        intended = np.array([2., -.6])
        finish = intended + .5 * (intended - start)
        contact = shapely.get_coordinates(shapely.LineString([start, finish]).intersection(walls))
        np.testing.assert_allclose(contact, [intended], atol=1e-12)

        # Inverting the endpoints of a straight displayed ray aims at x=1.75
        # instead. This was the incorrect old junction-test expectation.
        wrong_end = np.array([3., -1. - 1.2])
        wrong = shapely.get_coordinates(shapely.LineString([start, wrong_end]).intersection(walls))
        np.testing.assert_allclose(wrong, [[1.75, -.45]], atol=1e-12)
        self.assertGreater(np.linalg.norm(wrong[0] - intended), .25)


if __name__ == '__main__':
    unittest.main()
